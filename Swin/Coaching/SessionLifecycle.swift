import Foundation
import Observation

/// Single source of truth for "is a coaching session active and what's its ID".
///
/// User-driven, not automatic: nothing happens until `start()` is called and
/// nothing closes until `end()` is called. Tab switches and app backgrounding
/// don't affect anything.
///
/// Wires together:
///   - SwingArchive (disk)
///   - SessionCoach (in-memory state, streaks, focus)
///   - (later) SessionAnalyzer + LLM report generation on `end()`
@Observable
final class SessionLifecycle: @unchecked Sendable {
    enum Phase: Sendable, Equatable {
        case idle              // no session running
        case active            // session running, accepting swings
        case generatingReport  // user pressed End, analyzer + LLM running
        case reportReady       // report cached, ready to display
    }

    private(set) var phase: Phase = .idle
    private(set) var currentSession: SessionDirectory?
    private(set) var swingsThisSession: Int = 0
    /// What this session is focused on (chosen on the Session-onboarding
    /// screen). nil = "work on everything". Surfaced in the HUD and used to
    /// frame the end-of-session report.
    private(set) var sessionFocus: SwingFaultID?
    /// Optional target duration (minutes) the user picked. nil = no limit.
    private(set) var goalMinutes: Int?
    /// Optional target swing count the user picked. nil = no target. Mutually
    /// exclusive with `goalMinutes` (the onboarding screen picks one or the
    /// other). Surfaced in the HUD as a "x / N swings" progress readout.
    private(set) var goalSwings: Int?
    /// Free-text note the user typed to describe what they want to work on,
    /// when none of the suggested focuses fit. Carried into the report framing.
    private(set) var focusNote: String?
    /// Camera angle picked in session-onboarding (face-on vs down-the-line).
    /// Threaded into archive.openSession + the live SwingRecorder so metrics use
    /// the right viewpoint signs / hard-filter.
    private(set) var sessionViewpoint: Viewpoint = .downTheLine
    private(set) var sessionHandedness: Handedness = .right
    /// Last finalized session, if a report has been generated this app run.
    /// View layer reads this to navigate to a SessionReportView after End.
    private(set) var lastReportPath: URL? = nil
    /// Live-updating report during/after End. Replaced as LLM streams in.
    /// Nil while session is active or no session has ever closed.
    private(set) var lastReport: SessionReport? = nil
    /// SessionStats for the just-closed session. Persisted next to the report.
    private(set) var lastStats: SessionStats? = nil

    let archive: SwingArchive
    let coach: SessionCoach
    /// Used for the End → analyze → LLM-generate chain. Optional so that
    /// previews / tests can construct a lifecycle without a cloud service.
    var reportGenerator: SessionReportGenerator? = nil
    /// Optional finalizer: on End, we await this before processing per-swing
    /// video clips. RecordView wires it to `camera.stopSessionRecording()`
    /// so that the in-progress mp4 is fully written before we try to clip
    /// from it (otherwise AVAssetExportSession fails with "Cannot Open").
    var sessionVideoFinalizer: (@Sendable () async -> Void)?

    init(archive: SwingArchive, coach: SessionCoach) {
        self.archive = archive
        self.coach = coach
    }

    // MARK: - lifecycle

    /// User pressed "Start session" (after the Session-onboarding screen).
    /// `focus` = the issue to work on this session (nil = everything);
    /// `goalMinutes` = optional target duration. Idempotent.
    func start(focus: SwingFaultID? = nil, goalMinutes: Int? = nil,
               goalSwings: Int? = nil, focusNote: String? = nil,
               viewpoint: Viewpoint = .downTheLine,
               handedness: Handedness = .right) {
        guard phase == .idle || phase == .reportReady else { return }
        // Drop any leftover state from the previous session — undrained
        // pending clips, an in-flight re-analysis task, the analyzer's
        // .done status. Without this, session 2's chunk closures race
        // the previous session's tail on the shared VideoAnalyzer and
        // the second session appears frozen.
        archive.resetForNewSession()
        sessionViewpoint = viewpoint
        sessionHandedness = handedness
        let session = archive.openSession(startedAt: Date(), viewpoint: viewpoint,
                                          handedness: handedness == .right ? "right" : "left")
        // Seed the chosen focus so the coach commits to it from swing 1 in
        // "work on a specific issue" mode (nil = work on everything).
        coach.start(focus: focus)
        swingsThisSession = 0
        currentSession = session
        sessionFocus = focus
        self.goalMinutes = goalMinutes
        self.goalSwings = goalSwings
        self.focusNote = focusNote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? focusNote : nil
        lastReportPath = nil
        lastReport = nil
        lastStats = nil
        phase = .active
        print("[SessionLifecycle] started: \(session.id) focus=\(focus?.rawValue ?? "all")")
    }

    /// User pressed "End session". Closes the archive immediately, then runs
    /// SessionAnalyzer + LLM report generation on a background task.
    /// Phase transitions: active → generatingReport → reportReady.
    func end() {
        guard let session = currentSession, phase == .active else { return }
        phase = .generatingReport
        archive.closeSession(session)
        print("[SessionLifecycle] closed: \(session.id) (\(swingsThisSession) swings)")

        // The whole post-session pipeline (finalize mp4 → cut clips → LLM
        // report) runs in `work`. A `watchdog` guarantees we ALWAYS leave the
        // generatingReport state within a hard deadline: if anything hangs — a
        // stalled LLM stream that never sends [DONE], a stuck
        // AVAssetExportSession, a dead network — we cancel `work`, fall back to
        // the deterministic report, and flip to reportReady so the user isn't
        // trapped (phase stuck → start() refuses → app effectively frozen).
        let work = Task { [weak self] in
            guard let self else { return }
            // 0a. Wait for the per-swing pose+annotated writes that have been
            //     enqueued during the session.
            await self.archive.flush()
            // 0b. Wait for the camera (or replay source) to finalize the
            //     session mp4 — until this returns the file isn't valid and
            //     AVAssetExportSession would fail with "Cannot Open".
            if let finalizer = self.sessionVideoFinalizer {
                await finalizer()
            }
            // 0c. Now run the per-swing video clip jobs that we queued up.
            await self.archive.processPendingClips()
            // 0d. Prune video down to the permanent keep-set (best / problems /
            //     first-last / user-marked) and enforce the cross-session cap.
            //     Pose + annotated JSON is untouched, so analysis stays whole.
            self.archive.finalizeRetention(in: session)
            // Build the highlight reel FIRST (fast — just stitches the already-
            // pruned clips). MUST come before the slow re-analysis: otherwise the
            // watchdog can cancel end() mid-re-analysis and the reel never runs
            // (that was the "no highlight reel" bug).
            await self.archive.buildHighlightReel(in: session)
            self.archive.enforceCrossSessionCap()
            // Deferred upload-grade re-analysis: re-run pose (dense, from the
            // clip) + PoseTCN on each kept swing so History gets accurate pose +
            // event segmentation. This is SLOW (~2-5 s/swing) — must NOT run
            // inside `work`, or it blows past the 20 s watchdog, gets cancelled
            // mid-way (some swings upgraded, most not → wrong segmentation), and
            // wedges the report. Fire-and-forget on a background task instead:
            // the report + reel land fast, the UI unblocks, and saved swings get
            // upgraded over the next minute. LIVE inference is off (generatingReport)
            // so it won't fight the ANE.
            self.archive.startBackgroundReanalysis()
            // 1. Read the just-archived AnnotatedSwings off disk.
            let swings = self.archive.loadAnnotated(in: session)
            print("[SessionLifecycle] end() loaded \(swings.count) swings from archive")

            // 2. Build SessionStats. Optional cross-session compare with the
            //    most recent prior session (if any).
            let prevStats = self.loadPreviousStats(beforeSessionID: session.id)
            let stats = SessionAnalyzer().summarize(
                sessionID: session.id,
                startedAt: session.startedAt,
                endedAt: session.endedAt ?? Date(),
                swings: swings,
                previousSession: prevStats
            )
            await MainActor.run { self.lastStats = stats }
            self.persistStats(stats, in: session)

            // 3. Generate the LLM report (with streaming progress).
            //    If `reportGenerator` is nil (no API key), this returns the
            //    deterministic fallback immediately.
            let generator = self.reportGenerator
            let final: SessionReport
            if let generator {
                final = await generator.generate(stats: stats) { partial in
                    self.lastReport = partial
                }
            } else {
                final = SessionReport.fallback(from: stats)
                await MainActor.run { self.lastReport = final }
            }
            self.persistReport(final, in: session)

            await MainActor.run {
                self.lastReportPath = session.root.appendingPathComponent("session_report.json")
                self.phase = .reportReady
                print("[SessionLifecycle] report ready · headline: \(final.headline)")
            }
        }

        // Hard deadline. A healthy report lands in a few seconds; if we blow
        // past this the LLM (or a clip export) is wedged — cancel it, surface
        // whatever we have, and unblock the UI so a new session can start.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)   // 20 s
            guard let self, !Task.isCancelled else { return }
            work.cancel()
            await MainActor.run {
                guard self.phase == .generatingReport else { return }
                print("[SessionLifecycle] report watchdog fired — forcing reportReady")
                if self.lastReport == nil {
                    self.lastReport = self.lastStats.map(SessionReport.fallback(from:))
                }
                self.lastReportPath = session.root.appendingPathComponent("session_report.json")
                self.phase = .reportReady
            }
        }
        // Cancel the watchdog the moment the real pipeline finishes.
        Task { _ = await work.value; watchdog.cancel() }
    }

    // MARK: - persistence helpers

    private func loadPreviousStats(beforeSessionID currentID: String) -> SessionStats? {
        let sessions = archive.loadAllSessions().filter { $0.id != currentID }
        // archive.loadAllSessions returns newest first; the first one not == current is the previous.
        guard let prev = sessions.first else { return nil }
        let statsURL = prev.root.appendingPathComponent("session_stats.json")
        guard let data = try? Data(contentsOf: statsURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SessionStats.self, from: data)
    }

    private func persistStats(_ stats: SessionStats, in session: SessionDirectory) {
        let url = session.root.appendingPathComponent("session_stats.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(stats) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func persistReport(_ report: SessionReport, in session: SessionDirectory) {
        let url = session.root.appendingPathComponent("session_report.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(report) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// After viewing the report, return to a clean idle state.
    func dismissReport() {
        currentSession = nil
        swingsThisSession = 0
        phase = .idle
    }

    // MARK: - per-swing hook

    /// Called by the feedback orchestrator whenever a swing has been scored.
    /// Skips entirely when the session isn't active — that's how Live tab
    /// without an active session stays silent (no archive, no coach, no TTS).
    ///
    /// Returns true iff the caller should proceed with coaching / TTS for
    /// this swing.
    func noteFinishedSwing(annotated: AnnotatedSwing,
                            poseFrames: [PoseFrame],
                            sourceVideoURL: URL? = nil,
                            videoStartSeconds: Double? = nil,
                            videoEndSeconds: Double? = nil) -> Bool {
        guard phase == .active, let session = currentSession else {
            return false
        }
        swingsThisSession += 1
        archive.archive(
            annotated: annotated,
            poseFrames: poseFrames,
            sourceVideoURL: sourceVideoURL,
            videoStartSeconds: videoStartSeconds,
            videoEndSeconds: videoEndSeconds,
            into: session
        )
        return true
    }
}
