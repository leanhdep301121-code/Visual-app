import AVFoundation
import Foundation
import UIKit

/// Disk-backed archive of every swing produced during a session.
///
/// Layout under `Documents/SwingArchive/`:
///
///   sessions/
///     <session_id>/
///       session_meta.json         ← startedAt, endedAt, swing count, etc.
///       annotated/
///         swing_001.json          ← AnnotatedSwing per swing (~3 KB)
///         swing_002.json
///         ...
///       pose/
///         swing_001.json          ← compact pose dump per swing (~50-150 KB)
///         ...
///       video/                     ← present only for selected categories
///         swing_014.mp4
///         swing_022.mp4
///       thumbnails/
///         swing_014.jpg
///         ...
///       session_state.json        ← last SessionState snapshot
///       session_stats.json        ← computed by SessionAnalyzer (later step)
///       session_report.json       ← LLM-generated final report (later step)
///
/// Policies:
///   - Pose JSON: ALWAYS written (≈100 KB / swing → 500 MB / 5000 swings)
///   - Annotated JSON: ALWAYS written (≈3 KB / swing)
///   - Video: ONLY for category .clean or .problem (one good + one bad keeps
///            the session interesting; mid-range swings have no replay value)
///   - Thumbnail: only when we keep video
///
/// All disk writes happen on a background queue. Methods take what they need
/// (raw frames, source video URL, etc.) and don't assume any global state.
final class SwingArchive: @unchecked Sendable {
    let baseDir: URL
    private let ioQueue = DispatchQueue(label: "swin.archive.io", qos: .utility)
    private(set) var currentSession: SessionDirectory?
    /// Optional fresh-pose pipeline used right after each per-swing mp4 is
    /// exported: rerun the SAME pose + event extraction Upload uses,
    /// overwriting the live-captured pose JSON on disk with the cleaner
    /// version. Without this, History reads stale live-stream poses (lower
    /// fidelity, occasional joint drift) and overlays land off the body.
    var clipAnalyzer: VideoAnalyzer?

    /// Dynamic video-retention knobs (§3.5). Pose + annotated JSON is always
    /// kept; this only governs which swings keep their mp4 clip. See
    /// `RetentionPolicy`.
    var retention: RetentionConfig = .standard

    // Drain support: callers can await `flush()` to know that every previously
    // enqueued archive write has completed (pose JSON, annotated JSON, video clip).
    private let pendingLock = NSLock()
    private var pendingWrites: Int = 0
    private var pendingDrainContinuations: [CheckedContinuation<Void, Never>] = []

    /// Per-swing video-clip work queued during the session. We can't clip
    /// a session mp4 while AVAssetWriter is still writing to it, so the
    /// actual `AVAssetExportSession.export()` runs LATER — after
    /// `stopSessionRecording` has fully finalized the source. The session
    /// lifecycle drains this queue via `processPendingClips(...)` on End.
    private struct PendingClip {
        let swingNumber: Int
        let source: URL
        let start: Double
        let end: Double
        let session: SessionDirectory
    }
    private var pendingClips: [PendingClip] = []

    /// True when a swing from `source` is queued and waiting for that chunk to
    /// close. The camera uses this to roll the chunk EARLY (instead of waiting
    /// out `chunkDurationSeconds`) so the clip lands on disk seconds after the
    /// swing — that's what in-session replay plays from.
    ///
    /// ⚠️ Rolling before the clip is queued would be a data-loss race:
    /// `onChunkClosed` would find nothing to export and then delete the source
    /// chunk, losing the swing's video for good. Gate the early roll on this.
    func hasPendingClips(source: URL) -> Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return pendingClips.contains { $0.source == source }
    }

    /// Swings whose clip is exported mid-session but whose upload-grade
    /// re-analysis is DEFERRED to session end (see `onChunkClosed`). Running the
    /// re-analysis CoreML pipeline while LIVE pose/PoseTCN inference is active
    /// contends for the ANE and hangs. Drained by `drainReanalysis()`.
    private var pendingReanalysis: [(swing: Int, session: SessionDirectory)] = []

    /// Serialised tail of clip-reanalysis work. Each `reanalyzeClip` call
    /// chains onto this so two in-flight calls never race on the shared
    /// `clipAnalyzer`. Without serialisation, session 2's first chunk
    /// closure could fire `analyzer.analyze()` while session 1's tail
    /// reanalysis was still running — both would mutate the analyzer's
    /// `.status` / `.report` slots and the wrong poses landed in the
    /// wrong swing JSON, manifesting as a "frozen" second session.
    private var reanalysisChain: Task<Void, Never>?

    /// Suspend until every previously-enqueued archive write has finished.
    /// If no writes are pending, returns immediately.
    func flush() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pendingLock.lock()
            if pendingWrites == 0 {
                pendingLock.unlock()
                cont.resume()
            } else {
                pendingDrainContinuations.append(cont)
                pendingLock.unlock()
            }
        }
    }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.baseDir = docs.appendingPathComponent("SwingArchive/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    // MARK: - session lifecycle

    /// Open a new session directory. Returns a SessionDirectory the
    /// caller can hand around. Idempotent within the same calendar minute
    /// (re-opening returns the existing dir).
    func openSession(startedAt: Date = Date(),
                     viewpoint: Viewpoint = .downTheLine,
                     handedness: String = "right") -> SessionDirectory {
        let id = Self.idFor(date: startedAt)
        let dir = baseDir.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for sub in ["annotated", "pose", "video", "thumbnails", "diag"] {
            try? FileManager.default.createDirectory(
                at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let session = SessionDirectory(id: id, root: dir, startedAt: startedAt,
                                       viewpoint: viewpoint, handedness: handedness)
        currentSession = session
        writeSessionMeta(session)
        return session
    }

    /// Persist a tracker emit's argmax/probability trace. Called from the
    /// onSwingDiagnostic hook; small JSON (~a few KB per swing) that we always
    /// keep so a reported false positive can be re-analyzed offline.
    func archiveDiag(_ diag: SwingDiagnostic, into session: SessionDirectory) {
        ioQueue.async {
            let dir = session.root.appendingPathComponent("diag", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(
                String(format: "swing_%03d.json", diag.swingNumber))
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let data = try enc.encode(diag)
                try data.write(to: url, options: .atomic)
                dbg(tag: "arch", "wrote diag swing_\(diag.swingNumber) "
                    + "(\(diag.argmaxTrace.count) frames, \(diag.emitReason))")
            } catch {
                dbg(.error, tag: "arch", "diag write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Finalize a session by writing the closing meta. Subsequent archive
    /// of swings is rejected.
    func closeSession(_ session: SessionDirectory, endedAt: Date = Date()) {
        var updated = session
        updated.endedAt = endedAt
        writeSessionMeta(updated)
        if currentSession?.id == session.id { currentSession = nil }
    }

    // MARK: - per-swing archive

    /// Persist a finished swing. Pose JSON + AnnotatedSwing JSON are written
    /// synchronously on the IO queue; video extraction (if eligible) happens
    /// after that and may take a few seconds.
    ///
    /// `sourceVideoURL` is the on-disk mp4 the camera recorded for the full
    /// session; we trim a window around the swing into a per-swing clip.
    /// Pass nil if no recording is available (e.g. pure pose-only mode).
    func archive(
        annotated: AnnotatedSwing,
        poseFrames: [PoseFrame],
        sourceVideoURL: URL?,
        videoStartSeconds: Double?,
        videoEndSeconds: Double?,
        into session: SessionDirectory
    ) {
        pendingLock.lock(); pendingWrites += 1; pendingLock.unlock()
        Task { [self] in
            defer {
                pendingLock.lock(); pendingWrites -= 1
                if pendingWrites == 0 { pendingDrainContinuations.forEach { $0.resume() }; pendingDrainContinuations = [] }
                pendingLock.unlock()
            }
            do {
                try writePose(poseFrames, swingNumber: annotated.swingNumber, in: session)
                try writeAnnotated(annotated, in: session)
                dbg(tag: "arch", "archived #\(annotated.swingNumber) pose+json. "
                    + "videoSrc=\(sourceVideoURL?.lastPathComponent ?? "nil") "
                    + "range=[\(videoStartSeconds.map { String(format: "%.2f", $0) } ?? "nil")..\(videoEndSeconds.map { String(format: "%.2f", $0) } ?? "nil")]")
                // Defer the clipping: the active session mp4 is still being
                // written to disk, so AVAssetExportSession can't open it yet.
                // We queue a PendingClip and process them after the camera
                // finalizes the recording on End.
                if let src = sourceVideoURL,
                   let s = videoStartSeconds, let e = videoEndSeconds, e > s
                {
                    self.pendingLock.lock()
                    self.pendingClips.append(.init(
                        swingNumber: annotated.swingNumber, source: src,
                        start: s, end: e, session: session
                    ))
                    self.pendingLock.unlock()
                    dbg(tag: "arch", "queued clip #\(annotated.swingNumber) for end-of-session drain")
                    // NB: don't drain mid-session — `AVAssetWriter` hasn't
                    // finalized the source mp4 yet, so AVAssetExportSession
                    // can't read it reliably. `processPendingClips()` runs
                    // the queue once the camera has been stopped.
                } else {
                    dbg(.warn, tag: "arch", "skip video clip — missing src or range")
                }
                self.appendSessionIndex(swingNumber: annotated.swingNumber, in: session)
            } catch {
                dbg(.error, tag: "arch", "archive failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - listing / reading

    func loadAllSessions() -> [SessionDirectory] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: baseDir.path)
        else { return [] }
        var out: [SessionDirectory] = []
        for name in names {
            let root = baseDir.appendingPathComponent(name, isDirectory: true)
            guard var session = readSessionMeta(at: root) else { continue }
            // Always recompute swingCount at read time. The stored value in
            // session_meta.json lags behind because per-swing IO is async;
            // counting annotated/ on disk is authoritative and microsecond-cheap.
            let annotatedDir = root.appendingPathComponent("annotated")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: annotatedDir.path) {
                session.swingCount = files.filter { $0.hasSuffix(".json") }.count
            }
            out.append(session)
        }
        return out.sorted(by: { $0.startedAt > $1.startedAt })
    }

    /// Load the per-swing pose JSON and convert back to runtime PoseFrame
    /// (CMTime restored from the persisted seconds via `CMTimeMakeWithSeconds`).
    /// All poses are returned in the canonical anisotropic convention (kp.x
    /// in [0,1] of width, kp.y in [0,1] of height) — legacy iso dumps are
    /// converted on the fly so downstream consumers (PoseOverlay, Tiger
    /// silhouette, metrics, etc.) only deal with one convention.
    /// Returns nil if file missing or decode fails.
    func loadPoseFrames(swingNumber: Int, in session: SessionDirectory) -> [PoseFrame]? {
        let url = session.root
            .appendingPathComponent("pose")
            .appendingPathComponent(String(format: "swing_%03d.json", swingNumber))
        guard let data = try? Data(contentsOf: url),
              let dump = try? JSONDecoder().decode([PoseFrameDump].self, from: data)
        else { return nil }
        // iOS capture is always portrait 1080×1920 → aspect (W/H) = 9/16.
        // Used both as the imageAspect on loaded poses AND as the iso→aniso
        // multiplier for legacy iso dumps (anisoX = isoX / aspect = isoX*16/9).
        let liveAspect: Float = 1080.0 / 1920.0
        let isoToAniso: Float = 1 / liveAspect    // = 16/9 ≈ 1.778
        return dump.map { d in
            let t = CMTimeMakeWithSeconds(d.t, preferredTimescale: 600)
            // Default to iso for old dumps with no `iso` field — the only
            // producer before the flag was YOLO's iso path. New dumps store
            // the actual flag (typically false now that YOLO outputs aniso).
            let wasIso = d.iso ?? true
            let kp: [SIMD2<Float>] = zip(d.x, d.y).map { x, y in
                wasIso
                    ? SIMD2<Float>(x * isoToAniso, y)
                    : SIMD2<Float>(x, y)
            }
            return PoseFrame(timestamp: t,
                             keypoints: kp,
                             confidences: d.c,
                             isoNormalized: false,
                             imageAspect: liveAspect)
        }
    }

    /// Convenience: build a SwingReport from an archived AnnotatedSwing +
    /// its on-disk pose JSON. Lets the Archive UI open the same
    /// ProAnalysisView spec as Upload mode (phase scrubber, metrics, etc.).
    ///
    /// Metrics aren't persisted on disk because they're cheap to recompute
    /// from the poses + events we already have. Doing it here means archived
    /// swings show the full Metrics card instead of "events incomplete".
    func loadSwingReport(annotated: AnnotatedSwing,
                         in session: SessionDirectory,
                         videoSize: CGSize = CGSize(width: 1080, height: 1920)
                        ) -> SwingReport? {
        guard let poses = loadPoseFrames(swingNumber: annotated.swingNumber,
                                          in: session) else { return nil }
        let handedness: Handedness = (annotated.handedness == "left") ? .left : .right
        let events = SwingEvents(frames: annotated.eventFrames,
                                 handedness: handedness)
        let recordingURL: URL? = annotated.videoPath.map {
            session.root.appendingPathComponent($0)
        }
        let calc = MetricsCalculator()
        let metrics = calc.compute(poses: poses, events: events)
        let dynamics = calc.computeDynamics(poses: poses, events: events,
                                            viewpoint: session.viewpoint)
        return SwingReport(
            recordingURL: recordingURL,
            poseFrames: poses,
            events: events,
            metrics: metrics,
            perEvent: annotated.perEvent,
            dynamics: dynamics,
            ballTrajectory: nil,
            videoSize: videoSize,
            viewpoint: session.viewpoint
        )
    }

    func loadAnnotated(in session: SessionDirectory) -> [AnnotatedSwing] {
        let dir = session.root.appendingPathComponent("annotated")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var swings: [AnnotatedSwing] = []
        for name in names where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let a = try? dec.decode(AnnotatedSwing.self, from: data)
            else { continue }
            swings.append(a)
        }
        return swings.sorted(by: { $0.swingNumber < $1.swingNumber })
    }

    // MARK: - dynamic video retention (§3.5)

    private func videoURL(_ swingNumber: Int, in session: SessionDirectory) -> URL {
        session.root.appendingPathComponent("video")
            .appendingPathComponent(String(format: "swing_%03d.mp4", swingNumber))
    }
    private func thumbURL(_ swingNumber: Int, in session: SessionDirectory) -> URL {
        session.root.appendingPathComponent("thumbnails")
            .appendingPathComponent(String(format: "swing_%03d.jpg", swingNumber))
    }
    private func keepMarksURL(in session: SessionDirectory) -> URL {
        session.root.appendingPathComponent("keep_marks.json")
    }

    /// Clip URL for a swing, or nil while it hasn't landed on disk yet. The
    /// camera rolls the chunk early once a clip is queued, so this turns
    /// non-nil a few seconds after the swing — that's the signal in-session
    /// replay waits on.
    func clipURL(swingNumber: Int, in session: SessionDirectory) -> URL? {
        let u = videoURL(swingNumber, in: session)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Swing numbers the user explicitly asked to keep ("留这杆"). Always
    /// survive both the working-set eviction and the final prune. Backed by
    /// a tiny JSON so the mark persists across app launches.
    func userKeptSwings(in session: SessionDirectory) -> Set<Int> {
        guard let data = try? Data(contentsOf: keepMarksURL(in: session)),
              let arr = try? JSONDecoder().decode([Int].self, from: data) else { return [] }
        return Set(arr)
    }

    /// Mark a swing as user-kept. Idempotent. (Gesture / voice "keep this"
    /// wiring is a separate step; this is the persistence + policy hook.)
    func markKeep(swingNumber: Int, in session: SessionDirectory) {
        ioQueue.async {
            var marks = self.userKeptSwings(in: session)
            guard !marks.contains(swingNumber) else { return }
            marks.insert(swingNumber)
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            if let data = try? enc.encode(Array(marks).sorted()) {
                try? data.write(to: self.keepMarksURL(in: session), options: .atomic)
            }
            dbg(tag: "arch", "user kept swing #\(swingNumber)")
        }
    }

    /// Working-set gate used at clip-export time. A swing that isn't in the
    /// running candidate set never gets its clip exported at all — saving the
    /// AVAssetExportSession pass + reanalysis CoreML pass + disk, not just
    /// deleting after the fact. The data layer (pose+annotated JSON) is
    /// untouched, so the swing still appears in History / the report, just
    /// without replay video.
    func shouldExportVideo(swingNumber: Int, in session: SessionDirectory) -> Bool {
        let swings = loadAnnotated(in: session)
        let keep = RetentionPolicy.workingKeepSet(
            swings, userKept: userKeptSwings(in: session), cfg: retention)
        return keep.contains(swingNumber)
    }

    /// Mid-session eviction. Called after a chunk's clips are exported: any
    /// swing whose mp4 exists on disk but has aged out of the working set is
    /// deleted (video + thumbnail), keeping the live disk footprint bounded
    /// to ≈|working set| clips throughout an arbitrarily long session.
    func reconcileWorkingSet(in session: SessionDirectory) {
        let swings = loadAnnotated(in: session)
        let keep = RetentionPolicy.workingKeepSet(
            swings, userKept: userKeptSwings(in: session), cfg: retention)
        var evicted = 0
        for s in swings where !keep.contains(s.swingNumber) {
            let v = videoURL(s.swingNumber, in: session)
            if FileManager.default.fileExists(atPath: v.path) {
                try? FileManager.default.removeItem(at: v)
                try? FileManager.default.removeItem(at: thumbURL(s.swingNumber, in: session))
                evicted += 1
            }
        }
        if evicted > 0 {
            dbg(tag: "arch", "working-set evicted \(evicted) aged-out clip(s); keep=\(keep.count)")
        }
    }

    /// End-of-session prune. Now that the whole session is known, keep only
    /// the final ≈8-12 clips (best / representative problems / first-last /
    /// user-marked) and delete every other swing's mp4 + thumbnail. JSON
    /// stays — analysis is fully reproducible from pose + annotated.
    func finalizeRetention(in session: SessionDirectory) {
        let swings = loadAnnotated(in: session)
        guard !swings.isEmpty else { return }
        let keep = RetentionPolicy.finalKeepSet(
            swings, userKept: userKeptSwings(in: session), cfg: retention)
        var pruned = 0, kept = 0
        for s in swings {
            let v = videoURL(s.swingNumber, in: session)
            let exists = FileManager.default.fileExists(atPath: v.path)
            if keep.contains(s.swingNumber) {
                if exists { kept += 1 }
            } else if exists {
                try? FileManager.default.removeItem(at: v)
                try? FileManager.default.removeItem(at: thumbURL(s.swingNumber, in: session))
                pruned += 1
            }
        }
        dbg(tag: "arch", "final prune: kept \(kept) clip(s), pruned \(pruned) (of \(swings.count) swings)")
    }

    /// Cross-session cap. Keep video only for the most recent
    /// `maxSessionsWithVideo` sessions; older sessions lose their video/ +
    /// thumbnails/ contents (meta + JSON + report kept). Cheap — runs on End.
    func enforceCrossSessionCap() {
        let sessions = loadAllSessions()   // newest-first
        guard sessions.count > retention.maxSessionsWithVideo else { return }
        var cleared = 0
        for old in sessions.dropFirst(retention.maxSessionsWithVideo) {
            for sub in ["video", "thumbnails"] {
                let dir = old.root.appendingPathComponent(sub)
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
                      !files.isEmpty else { continue }
                for f in files {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
                }
                cleared += 1
            }
            // Also drop the old session's highlight reel — keeps total video
            // footprint bounded to the most-recent N sessions.
            let reel = old.root.appendingPathComponent("reel.mp4")
            if FileManager.default.fileExists(atPath: reel.path) {
                try? FileManager.default.removeItem(at: reel)
            }
        }
        if cleared > 0 {
            dbg(tag: "arch", "cross-session cap: cleared video from \(sessions.count - retention.maxSessionsWithVideo) old session(s)")
        }
    }

    // MARK: - private writers

    private func writePose(_ frames: [PoseFrame], swingNumber: Int,
                            in session: SessionDirectory) throws {
        let dump = frames.map { PoseFrameDump(from: $0) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(dump)
        let url = session.root
            .appendingPathComponent("pose")
            .appendingPathComponent(String(format: "swing_%03d.json", swingNumber))
        try data.write(to: url, options: .atomic)
    }

    private func writeAnnotated(_ a: AnnotatedSwing, in session: SessionDirectory) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(a)
        let url = session.root
            .appendingPathComponent("annotated")
            .appendingPathComponent(String(format: "swing_%03d.json", a.swingNumber))
        try data.write(to: url, options: .atomic)
    }

    /// Called when CameraService finalizes a session chunk mp4. Drains all
    /// PendingClips whose `source` matches the finalized chunk — those
    /// swings can now be exported (the chunk's moov atom is written).
    /// Deletes the chunk file after its clips are extracted to keep
    /// Documents/ from ballooning over a long session.
    func onChunkClosed(url: URL) async {
        pendingLock.lock()
        let mine = pendingClips.filter { $0.source == url }
        pendingClips.removeAll { $0.source == url }
        pendingLock.unlock()
        if !mine.isEmpty {
            dbg(tag: "arch",
                "chunk \(url.lastPathComponent) closed — \(mine.count) clip(s) queued")
            for clip in mine {
                // Working-set gate: only export clips worth keeping right now.
                // Aged-out mid-range swings keep their JSON but never burn an
                // export + reanalysis pass. (§3.5)
                guard shouldExportVideo(swingNumber: clip.swingNumber, in: clip.session) else {
                    dbg(tag: "arch", "skip clip #\(clip.swingNumber) — not in working set")
                    continue
                }
                do {
                    try await clipVideoAsync(
                        source: clip.source, start: clip.start, end: clip.end,
                        swingNumber: clip.swingNumber, in: clip.session
                    )
                    try writeThumbnail(
                        source: clip.source, atSeconds: (clip.start + clip.end) / 2,
                        swingNumber: clip.swingNumber, in: clip.session
                    )
                    // DEFER the upload-grade re-analysis to session end. Its
                    // CoreML pipeline (pose+PoseTCN+ball+club) run mid-session
                    // fights the LIVE pose/PoseTCN for the ANE and hangs the app
                    // (~2 swings in, at the first chunk close). The clip is
                    // already exported; drainReanalysis() upgrades the overlay
                    // once live inference is off.
                    pendingLock.lock()
                    pendingReanalysis.append((clip.swingNumber, clip.session))
                    pendingLock.unlock()
                } catch {
                    dbg(.error, tag: "arch",
                        "clip #\(clip.swingNumber) failed: \(error.localizedDescription)")
                }
            }
            // Drop clips that have aged out of the working set since they were
            // exported, so the live footprint stays bounded over a long session.
            if let session = mine.first?.session { reconcileWorkingSet(in: session) }
        }
        try? FileManager.default.removeItem(at: url)
        dbg(tag: "arch", "chunk \(url.lastPathComponent) removed from disk")
    }

    /// Run the upload-grade pipeline on the freshly-exported per-swing
    /// mp4 and overwrite the on-disk pose JSON + events. This is what
    /// makes History overlays match Upload's quality — the cleaner
    /// pose stream replaces whatever live capture managed to sample.
    ///
    /// Serialised through `reanalysisChain` so concurrent callers (chunk
    /// closures from session N AND session N+1's tail) don't trample
    /// the shared analyzer's `.status` / `.report` slots.
    private func reanalyzeClip(swingNumber: Int, in session: SessionDirectory) async {
        guard let analyzer = clipAnalyzer else { return }
        let clipURL = session.root
            .appendingPathComponent("video")
            .appendingPathComponent(String(format: "swing_%03d.mp4", swingNumber))
        guard FileManager.default.fileExists(atPath: clipURL.path) else { return }
        // Read+write of `reanalysisChain` happens under `pendingLock` so two
        // concurrent callers can't both observe `previous == nil` and race
        // on the shared analyzer. Without this lock the serialisation falls
        // apart whenever a session-end drain overlaps a live chunk close.
        pendingLock.lock()
        let previous = reanalysisChain
        let job = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if Task.isCancelled { return }
            dbg(tag: "arch", "re-analyzing swing #\(swingNumber) with upload-grade pipeline")
            analyzer.reset()
            await analyzer.analyze(url: clipURL, viewpoint: session.viewpoint,
                                   handedness: session.handedness)
            if Task.isCancelled { return }
            guard let fresh = analyzer.report else {
                dbg(.warn, tag: "arch", "re-analysis returned nil for swing #\(swingNumber)")
                return
            }
            self.applyReanalysis(fresh: fresh, swingNumber: swingNumber, in: session)
        }
        reanalysisChain = job
        pendingLock.unlock()
        await job.value
    }

    /// Re-analyze every swing deferred by `onChunkClosed`. MUST run only when
    /// live camera inference is OFF (session end) — two CoreML pipelines on the
    /// ANE at once hang the app. Serial, so ANE pressure stays bounded.
    /// Background handle for the deferred re-analysis drain. Cancelled the
    /// moment a new session starts so a prior session's dense-pose re-analysis
    /// (ANE) never fights the NEW session's LIVE pose/PoseTCN — that ANE
    /// contention is exactly what hung/stuttered capture.
    private var reanalysisDrainTask: Task<Void, Never>?

    /// Kick off the deferred re-analysis on a low-priority background task.
    /// Cancellable via `resetForNewSession`.
    func startBackgroundReanalysis() {
        reanalysisDrainTask?.cancel()
        reanalysisDrainTask = Task.detached(priority: .utility) { [weak self] in
            await self?.drainReanalysis()
        }
    }

    func drainReanalysis() async {
        pendingLock.lock()
        let jobs = pendingReanalysis
        pendingReanalysis.removeAll()
        pendingLock.unlock()
        guard !jobs.isEmpty else { return }
        dbg(tag: "arch", "draining \(jobs.count) deferred re-analysis job(s) in background")
        for j in jobs {
            if Task.isCancelled { dbg(tag: "arch", "re-analysis drain cancelled (new session)"); break }
            await reanalyzeClip(swingNumber: j.swing, in: j.session)
        }
    }

    /// Persist the re-analysed pose JSON + patch the AnnotatedSwing's
    /// eventFrames + perEvent. Split out of `reanalyzeClip` so the
    /// serialised task can hand off cleanly.
    private func applyReanalysis(fresh: SwingReport, swingNumber: Int, in session: SessionDirectory) {
        // Overwrite pose JSON with the fresh poses.
        do {
            try writePose(fresh.poseFrames, swingNumber: swingNumber, in: session)
        } catch {
            dbg(.error, tag: "arch", "re-analysis pose write failed: \(error)")
        }
        // Patch the AnnotatedSwing on disk: replace eventFrames + perEvent
        // with the fresh ones, leave coach-facing fields (faults, score,
        // category, topProblem/Strength) intact since those drove live TTS.
        let annotatedURL = session.root
            .appendingPathComponent("annotated")
            .appendingPathComponent(String(format: "swing_%03d.json", swingNumber))
        guard let data = try? Data(contentsOf: annotatedURL) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard var existing = try? dec.decode(AnnotatedSwing.self, from: data) else { return }
        existing.eventFrames = fresh.events.frames
        existing.perEvent = fresh.perEvent
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let newData = try? enc.encode(existing) {
            try? newData.write(to: annotatedURL, options: .atomic)
            dbg(tag: "arch", "re-analysis OK swing #\(swingNumber) (events=\(fresh.events.frames))")
        }
        writeBallSidecar(fresh: fresh, swingNumber: swingNumber, in: session)
    }

    /// Per-swing ball-pipeline dump — the data-flywheel record. Everything
    /// needed to replay/re-fit this shot offline: detections, fitted flight,
    /// predicted arc, and the intrinsics+gravity snapshot the solver used.
    private struct BallSidecar: Codable {
        let capturedAt: Date
        let deviceModel: String
        let ballFlight: BallFlight?
        let ballTrajectory: BallTrajectory?
        let clubTrackPointCount: Int
        /// Raw camera_intrinsics_latest.json contents (fx/fy/cx/cy/gravity),
        /// re-snapshotted at this shot's record-start.
        let intrinsicsJSON: String?
    }

    private func writeBallSidecar(fresh: SwingReport, swingNumber: Int, in session: SessionDirectory) {
        let dir = session.root.appendingPathComponent("ball")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var intrinsics: String? = nil
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? Data(contentsOf: docs.appendingPathComponent("camera_intrinsics_latest.json")) {
            intrinsics = String(data: data, encoding: .utf8)
        }
        let sidecar = BallSidecar(
            capturedAt: Date(),
            deviceModel: UIDevice.current.model + " " + UIDevice.current.systemVersion,
            ballFlight: fresh.ballFlight,
            ballTrajectory: fresh.ballTrajectory,
            clubTrackPointCount: fresh.clubTrack?.points.count ?? 0,
            intrinsicsJSON: intrinsics)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(sidecar) {
            let url = dir.appendingPathComponent(String(format: "swing_%03d.json", swingNumber))
            try? data.write(to: url, options: .atomic)
            dbg(tag: "arch", "ball sidecar swing #\(swingNumber): flight=\(fresh.ballFlight != nil) traj=\(fresh.ballTrajectory?.points.count ?? 0)pts")
        }
    }

    /// Bring the archive back to a clean per-session baseline. Clears
    /// any undrained pending clips (session 1's tail never got picked up)
    /// and snaps the analyzer back to `.idle`. Keeps the reanalysis chain
    /// intact so session 2's first reanalysis still queues behind any
    /// still-running session-1 work — the user's Start tap is not blocked
    /// because we don't await the chain here. Called from
    /// `SessionLifecycle.start()` before opening the new session dir.
    func resetForNewSession() {
        // Cancel any still-running background re-analysis from the PREVIOUS
        // session — its dense-pose ANE work must not fight this session's live
        // pose/PoseTCN inference (that contention hangs/stutters capture).
        reanalysisDrainTask?.cancel()
        pendingLock.lock()
        let droppedClips = pendingClips.count
        pendingClips.removeAll()
        pendingReanalysis.removeAll()
        let chain = reanalysisChain
        // Detach the chain — don't await it here (we don't want to block
        // the user's Start tap on a long-running session-1 tail), but
        // crucially don't `nil` it either: the previous task value is
        // what guarantees session 2's first reanalysis won't race with
        // session 1's last one on the shared analyzer.
        pendingLock.unlock()
        clipAnalyzer?.reset()
        if droppedClips > 0 {
            dbg(.warn, tag: "arch", "dropped \(droppedClips) stale pending clip(s) on new session")
        } else {
            dbg(tag: "arch", "archive reset for new session")
        }
        _ = chain  // referenced so the previous chain isn't deallocated mid-await
    }

    /// End-of-session backstop. With chunk-based recording most clips
    /// are exported in the background as chunks finalize during the
    /// session, so by the time this runs the queue is usually empty.
    /// Still keeps a serial fallback in case any clips slipped past
    /// `onChunkClosed` (e.g. session ended before a chunk closure).
    func processPendingClips() async {
        pendingLock.lock()
        let clips = pendingClips
        pendingClips.removeAll()
        pendingLock.unlock()
        guard !clips.isEmpty else {
            dbg(tag: "arch", "no pending clips to process at session end")
            return
        }
        dbg(tag: "arch", "session-end drain: \(clips.count) pending clip(s)")
        for clip in clips {
            // Same working-set gate as mid-session. The final prune in
            // `finalizeRetention` runs right after this drain and trims down
            // to the permanent keep-set; gating here avoids exporting clips
            // that would be pruned moments later.
            guard shouldExportVideo(swingNumber: clip.swingNumber, in: clip.session) else {
                dbg(tag: "arch", "skip end-drain clip #\(clip.swingNumber) — not in working set")
                continue
            }
            do {
                // The clip CUT (fast passthrough export) + thumbnail are what
                // the report and History video actually need — keep these
                // awaited so the video exists before we return.
                try await clipVideoAsync(
                    source: clip.source, start: clip.start, end: clip.end,
                    swingNumber: clip.swingNumber, in: clip.session
                )
                try writeThumbnail(
                    source: clip.source, atSeconds: (clip.start + clip.end) / 2,
                    swingNumber: clip.swingNumber, in: clip.session
                )
                // The upload-grade RE-ANALYSIS (full YOLO + PoseTCN per swing)
                // only refines the History pose overlay — the report doesn't
                // depend on it. Running it inline + awaited here meant
                // `end()` blocked on N serial CoreML passes (tens of seconds for
                // a long session) before the report even started — that was the
                // "generating report froze" stall. Fire it detached so the
                // report proceeds immediately; reanalysisChain still serialises
                // the background jobs so they don't trample each other.
                let n = clip.swingNumber, sess = clip.session
                Task { [weak self] in await self?.reanalyzeClip(swingNumber: n, in: sess) }
            } catch {
                dbg(.error, tag: "arch",
                    "clip #\(clip.swingNumber) failed: \(error.localizedDescription)")
            }
        }
        // We own the final-chunk drain now (stopSessionRecording no longer fires
        // onChunkClosed), so clean up the source chunk files here — only AFTER
        // every clip above has been fully exported, so we never delete a file
        // mid-export. Dedup since several swings can share one chunk.
        let chunkFiles = Set(clips.map(\.source))
        for url in chunkFiles {
            try? FileManager.default.removeItem(at: url)
            dbg(tag: "arch", "chunk \(url.lastPathComponent) removed after end-of-session drain")
        }
    }

    /// Async clip. Uses modern AVAsset async-load APIs so duration / track
    /// queries don't trip the iOS 16+ deprecation hazards.
    /// Output extension is `.mov` for passthrough compatibility with iPhone
    /// source files (they're QuickTime regardless of suffix); UI plays both
    /// `.mov` and `.mp4` transparently via AVPlayer.
    private func clipVideoAsync(
        source: URL, start: Double, end: Double,
        swingNumber: Int, in session: SessionDirectory
    ) async throws {
        let outURL = session.root
            .appendingPathComponent("video")
            .appendingPathComponent(String(format: "swing_%03d.mp4", swingNumber))
        try? FileManager.default.removeItem(at: outURL)
        dbg(tag: "arch", "clip swing #\(swingNumber) [\(String(format: "%.2f", start))..\(String(format: "%.2f", end))] from \(source.lastPathComponent)")

        guard FileManager.default.fileExists(atPath: source.path) else {
            dbg(.error, tag: "arch", "source missing: \(source.path)")
            throw NSError(domain: "SwingArchive", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "source missing"])
        }
        let asset = AVURLAsset(url: source)
        // Modern async load — required on iOS 16+ where `asset.duration` is
        // deprecated and the synchronous form returns garbage for some clips.
        let duration: CMTime
        let tracks: [AVAssetTrack]
        do {
            (duration, tracks) = try await (asset.load(.duration), asset.loadTracks(withMediaType: .video))
        } catch {
            dbg(.error, tag: "arch", "asset load failed: \(error.localizedDescription)")
            throw error
        }
        let assetSec = CMTimeGetSeconds(duration)
        let s = max(0, min(start, assetSec - 0.1))
        let e = max(s + 0.1, min(end, assetSec))
        let range = CMTimeRange(
            start: CMTime(seconds: s, preferredTimescale: 600),
            duration: CMTime(seconds: e - s, preferredTimescale: 600)
        )
        dbg(tag: "arch", "asset dur=\(String(format: "%.2f", assetSec))s, "
            + "tracks=\(tracks.count), range=[\(s)..\(e)]")

        // Try `.passthrough` first — it copies H.264 chunks verbatim
        // (no re-encode), so a 3 s clip exports in ~200 ms. Safe now that
        // VideoRecorder writes a regular mp4 with moov-at-end (fragmented
        // mp4 is what broke passthrough's time-range alignment last time).
        // Fall back to `.highestQuality` re-encode if passthrough fails
        // for any reason. Both preserve source dimensions + transform.
        let presets: [String] = [
            AVAssetExportPresetPassthrough,
            AVAssetExportPresetHighestQuality,
        ]
        var lastError: String = ""
        for preset in presets {
            guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
                lastError = "no session for \(preset)"
                continue
            }
            export.outputURL = outURL
            export.outputFileType = .mp4
            export.timeRange = range
            export.shouldOptimizeForNetworkUse = true
            try? FileManager.default.removeItem(at: outURL)
            await export.export()
            if export.status == .completed {
                let bytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
                dbg(tag: "arch", "wrote swing_\(swingNumber).mp4 via \(preset) (\(bytes / 1024) KB)")
                return
            }
            let err = export.error?.localizedDescription ?? "status=\(export.status.rawValue)"
            dbg(.warn, tag: "arch", "preset \(preset) failed: \(err)")
            lastError = err
        }
        dbg(.error, tag: "arch", "all export presets failed: \(lastError)")
        throw NSError(domain: "SwingArchive", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "export failed: \(lastError)"])
    }

    private func writeThumbnail(source: URL, atSeconds: Double,
                                  swingNumber: Int, in session: SessionDirectory) throws {
        let asset = AVURLAsset(url: source)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 720)
        let t = CMTime(seconds: atSeconds, preferredTimescale: 600)
        let cg = try gen.copyCGImage(at: t, actualTime: nil)
        let ui = UIImage(cgImage: cg)
        guard let data = ui.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "SwingArchive", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "jpeg encode failed"])
        }
        let url = session.root
            .appendingPathComponent("thumbnails")
            .appendingPathComponent(String(format: "swing_%03d.jpg", swingNumber))
        try data.write(to: url, options: .atomic)
    }

    // MARK: - session meta

    private func writeSessionMeta(_ s: SessionDirectory) {
        let url = s.root.appendingPathComponent("session_meta.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(s) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func readSessionMeta(at root: URL) -> SessionDirectory? {
        let url = root.appendingPathComponent("session_meta.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard var meta = try? dec.decode(SessionDirectory.self, from: data) else { return nil }
        // The stored root is an ABSOLUTE container URL, and iOS moves the data
        // container on every app update — so the persisted path goes stale and
        // stats/report/clip loads silently 404. The directory we just scanned
        // is authoritative; always override.
        meta.root = root
        return meta
    }

    private func appendSessionIndex(swingNumber: Int, in session: SessionDirectory) {
        // session_meta.json's `swingCount` is a derived field. We keep it
        // honest by re-counting the annotated/ dir whenever we archive.
        let dir = session.root.appendingPathComponent("annotated")
        let n = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? 0
        var updated = session
        updated.swingCount = n
        writeSessionMeta(updated)
    }

    private static func idFor(date: Date) -> String {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        return df.string(from: date)
    }
}

// MARK: - SessionDirectory

/// Lightweight handle to a session's folder on disk.
struct SessionDirectory: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var root: URL
    var startedAt: Date
    var endedAt: Date? = nil
    /// Derived: number of annotated swings written so far.
    var swingCount: Int = 0
    /// Camera angle this session was shot from (picked in session-onboarding).
    /// Drives viewpoint-aware metric signs + the viewpoint hard-filter when the
    /// session's swings are (re)analyzed. Defaults to down-the-line for old
    /// sessions written before this field existed.
    var viewpoint: Viewpoint = .downTheLine
    /// Handedness picked in session-onboarding ("right" | "left"). Drives the
    /// overlay mirroring + toward-target metric signs when swings are
    /// (re)analyzed. Stored as a string so SessionDirectory stays Codable;
    /// defaults to right-handed for sessions written before this field existed.
    var handedness: String = "right"
}

// MARK: - pose dump (compact)

/// Compact on-disk pose form. PoseFrame itself is non-Codable (CMTime),
/// so we project it down to plain numbers.
private struct PoseFrameDump: Codable {
    let t: Double            // presentation time seconds
    let x: [Float]           // 17 normalized x coords
    let y: [Float]           // 17 normalized y coords
    let c: [Float]           // 17 confidences
    /// True if x and y were both divided by the rotated frame's height (YOLO
    /// live path). False / missing → Vision's standard [0,1]×[0,1] convention.
    /// Optional so older dumps decode cleanly; loader defaults to true (the
    /// only producer of archived poses before this field existed was YOLO).
    let iso: Bool?
    init(from p: PoseFrame) {
        self.t = CMTimeGetSeconds(p.timestamp)
        self.x = p.keypoints.map { $0.x }
        self.y = p.keypoints.map { $0.y }
        self.c = p.confidences
        self.iso = p.isoNormalized
    }
}

// MARK: - Highlight reel (session montage)

extension SwingArchive {
    /// Path to the session's highlight reel, if one has been built.
    func reelURL(in session: SessionDirectory) -> URL? {
        let u = session.root.appendingPathComponent("reel.mp4")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Build (or rebuild) the session highlight reel: stitch the best readable
    /// swings' clips — in chronological order so it reads as a first→last
    /// progress montage — into a single `reel.mp4` at the session root.
    ///
    /// Storage: reuses the already-pruned keep-set clips (best/problem/first-
    /// last, ≈8-12), so NO extra source video is retained. The reel is the one
    /// shareable artifact; the full session mp4 was already deleted chunk-by-
    /// chunk during recording. Needs ≥2 clips on disk to be worth making.
    /// `rampCount` (preset) = how many of the best swings get the dramatic
    /// slow-mo speed ramp; the rest play real time. Small = punchy interspersed
    /// slow-mo — e.g. 1 means "one hero swing in slow-mo, the rest full speed".
    @discardableResult
    func buildHighlightReel(in session: SessionDirectory,
                            maxClips: Int = 8, rampCount: Int = 2) async -> URL? {
        let swings = loadAnnotated(in: session)
        guard !swings.isEmpty else { return nil }
        let readable = swings.filter { $0.category != .unreadable }
        let bestSorted = readable.sorted { $0.score.total > $1.score.total }
        let best = Set(bestSorted.prefix(maxClips).map(\.swingNumber))
        // Only the top-scored few get the slow-mo ramp, interspersed among the
        // real-time swings so the reel keeps a rhythm instead of dragging.
        let rampSet = Set(bestSorted.prefix(max(0, min(rampCount, maxClips))).map(\.swingNumber))
        let ordered = swings.filter { best.contains($0.swingNumber) }
                            .sorted { $0.swingNumber < $1.swingNumber }
        let clips: [HighlightReel.Clip] = ordered.compactMap { sw in
            let url = videoURL(sw.swingNumber, in: session)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            // Impact as a FRACTION of the swing (robust to clip-vs-pose-buffer
            // padding): eventFrames are @30fps into the pose buffer whose span
            // is durationSeconds; map that fraction onto the real clip length.
            let impIdx = sw.eventFrames.indices.contains(SwingEvent.impact.rawValue)
                ? sw.eventFrames[SwingEvent.impact.rawValue] : -1
            let frac: Double? = (impIdx >= 0 && sw.durationSeconds > 0.1)
                ? min(1, max(0, (Double(impIdx) / 30.0) / sw.durationSeconds)) : nil
            return HighlightReel.Clip(url: url, impactFraction: frac,
                                      ramp: rampSet.contains(sw.swingNumber))
        }
        guard clips.count >= 2 else {
            dbg(tag: "arch", "reel: only \(clips.count) clip(s) on disk — skip")
            return nil
        }
        let out = session.root.appendingPathComponent("reel.mp4")
        let url = await HighlightReel.build(clips, to: out)
        dbg(tag: "arch", url != nil
            ? "highlight reel: \(clips.count) clips → reel.mp4"
            : "highlight reel: build FAILED")
        return url
    }
}

/// Stitches per-swing mp4 clips into one reel via `AVMutableComposition`, with
/// an optional per-swing speed ramp (fast approach → slow-mo strike → fast out)
/// anchored on impact. Video-only — the ramp makes swing audio meaningless, so
/// a music bed can be laid over the reel later. Same-session clips share
/// orientation + codec, so a single composition track + source transform works.
enum HighlightReel {
    struct Clip {
        let url: URL
        /// Impact position as a fraction [0,1] of the clip. nil → can't ramp.
        let impactFraction: Double?
        /// Give THIS clip the slow-mo speed ramp? False → plays at real time.
        /// Interspersing only a few ramped clips keeps the reel punchy.
        let ramp: Bool
    }

    @discardableResult
    static func build(_ clips: [Clip], to output: URL) async -> URL? {
        guard !clips.isEmpty else { return nil }
        let comp = AVMutableComposition()
        guard let vComp = comp.addMutableTrack(withMediaType: .video,
                                               preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        var transformSet = false
        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            guard let vSrc = try? await asset.loadTracks(withMediaType: .video).first,
                  let dur = try? await asset.load(.duration), CMTimeGetSeconds(dur) > 0.2
            else { continue }
            let clipStart = vComp.timeRange.duration        // append at current end
            do {
                try vComp.insertTimeRange(CMTimeRange(start: .zero, duration: dur),
                                          of: vSrc, at: clipStart)
            } catch { continue }                            // skip a bad clip
            if !transformSet, let t = try? await vSrc.load(.preferredTransform) {
                vComp.preferredTransform = t
                transformSet = true
            }
            if clip.ramp, let frac = clip.impactFraction {
                applyRamp(vComp, clipStart: clipStart, clipDur: dur,
                          impactSec: CMTimeGetSeconds(dur) * frac)
            }
        }
        guard vComp.timeRange.duration > .zero,
              let export = AVAssetExportSession(asset: comp,
                                                presetName: AVAssetExportPresetHighestQuality)
        else { return nil }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        return export.status == .completed ? output : nil
    }

    /// Speed-ramp one clip IN PLACE: fast approach → slow-mo strike → fast out,
    /// centered on `impactSec`. Segments are scaled last→first so each earlier
    /// segment's start offset stays valid as later ones change length.
    private static func applyRamp(_ track: AVMutableCompositionTrack,
                                  clipStart: CMTime, clipDur: CMTime, impactSec: Double) {
        let dur = CMTimeGetSeconds(clipDur)
        let imp = min(max(impactSec, 0), dur)
        let w0 = max(0, imp - 0.35)          // enter slow-mo just before impact
        let w1 = min(dur, imp + 0.50)        // exit after the strike
        // (localStart, localEnd, speed×)
        var segs: [(Double, Double, Double)] = []
        if w0 > 0.05       { segs.append((0,  w0,  1.6)) }   // fast approach
        if w1 > w0 + 0.05  { segs.append((w0, w1,  0.30)) }  // slow-mo strike
        if dur > w1 + 0.05 { segs.append((w1, dur, 1.3)) }   // brisk finish
        let ts: CMTimeScale = 600
        for (a, b, speed) in segs.reversed() {
            let range = CMTimeRange(
                start: clipStart + CMTime(seconds: a, preferredTimescale: ts),
                duration: CMTime(seconds: b - a, preferredTimescale: ts))
            track.scaleTimeRange(range, toDuration: CMTime(seconds: (b - a) / speed,
                                                           preferredTimescale: ts))
        }
    }
}
