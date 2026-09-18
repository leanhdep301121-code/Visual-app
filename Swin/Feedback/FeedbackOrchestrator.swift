import CoreMedia
import Foundation
import Observation

/// How often the coach actually says something / runs the LLM. Archiving
/// + per-swing state tracking always happens; this only controls the
/// LLM call + TTS for a swing.
enum CoachingCadence: Int, Sendable, CaseIterable {
    case off = 0          // total silence — no LLM, no TTS, but swings still archived
    case everySwing = 1
    case everyThree = 3
    case everyFive = 5

    var label: String {
        switch self {
        case .off:         return String(localized: "关")
        case .everySwing:  return String(localized: "每杆")
        case .everyThree:  return String(localized: "每3杆")
        case .everyFive:   return String(localized: "每5杆")
        }
    }
    var systemImage: String {
        switch self {
        case .off:         return "speaker.slash.fill"
        case .everySwing:  return "speaker.wave.3.fill"
        case .everyThree:  return "speaker.wave.2.fill"
        case .everyFive:   return "speaker.wave.1.fill"
        }
    }
    func next() -> CoachingCadence {
        switch self {
        case .everySwing: return .everyThree
        case .everyThree: return .everyFive
        case .everyFive:  return .off
        case .off:        return .everySwing
        }
    }
}

@Observable
final class FeedbackOrchestrator: @unchecked Sendable {
    private(set) var currentResponse: FeedbackResponse?
    private(set) var isLoading: Bool = false
    private(set) var lastError: String?
    /// Last rule-based diagnosis (ranked faults + tier + sub-scores). Exposed
    /// so a debug panel can show exactly what `SwingFaultDetector` produced,
    /// separately from how the LLM phrased it. This is how you verify the
    /// rule engine is actually running and ranking correctly.
    private(set) var lastScore: SwingScore?
    /// Last analyzed report's dynamics, for the same debug panel (head
    /// stability, hip drift, etc. — confirms the new metrics computed).
    private(set) var lastDynamics: SwingDynamics?

    /// Local user profile (handedness, body info, INTERNAL level, focus
    /// candidates, rolling fault tally). Drives onboarding gate, session focus
    /// recommendations, and level-based tuning. Persisted on disk (no cloud).
    private(set) var userProfile: UserProfile = UserProfileStore.load()

    /// Mutate + persist the profile.
    func updateProfile(_ block: (inout UserProfile) -> Void) {
        block(&userProfile)
        UserProfileStore.save(userProfile)
    }

    /// Build the initial profile from the onboarding swing the user uploaded:
    /// rank its faults → top few become focus candidates, fault counts seed the
    /// rolling tally, and severity infers an INTERNAL level (never shown to the
    /// user — people don't want to be labeled a beginner; we just track it to
    /// tune thresholds / tone / density).
    func completeOnboarding(report: SwingReport?, handedness: String, heightCm: Double?) {
        var candidates: [String] = []
        var tally: [String: Int] = [:]
        var level = "beginner"
        if let report {
            let faults = SwingScorer().score(report: report).faults
            candidates = faults.prefix(4).map { $0.id.rawValue }
            for f in faults { tally[f.id.rawValue, default: 0] += 1 }
            level = Self.inferLevel(faults)
        }
        updateProfile {
            $0.onboarded = true
            $0.handedness = handedness
            $0.heightCm = heightCm
            $0.inferredLevel = level
            $0.focusCandidates = candidates
            $0.faultTally = tally
        }
    }

    /// Coarse internal level from a swing's faults. Engineering heuristic;
    /// refined later. More significant faults → lower level.
    static func inferLevel(_ faults: [SwingFault]) -> String {
        let significant = faults.filter { $0.severity >= 0.6 }.count
        if significant >= 4 { return "beginner" }
        if significant >= 2 { return "intermediate" }
        return "advanced"
    }

    /// Suggested session focuses, ranked: onboarding candidates (recency-ish
    /// weight) + the rolling fault tally (how often it keeps showing up). Used
    /// by the Session-onboarding screen to recommend what to work on.
    func recommendedFocuses() -> [SwingFaultID] {
        var score: [String: Double] = [:]
        let n = userProfile.focusCandidates.count
        for (i, id) in userProfile.focusCandidates.enumerated() {
            score[id, default: 0] += Double(n - i)            // top candidate weighs most
        }
        for (id, count) in userProfile.faultTally {
            score[id, default: 0] += Double(count) * 0.5      // history reinforces
        }
        return score.sorted { $0.value > $1.value }
            .compactMap { SwingFaultID(rawValue: $0.key) }
            .prefix(4).map { $0 }
    }

    /// Fold a finished swing's faults into the rolling tally so future focus
    /// suggestions reflect what actually keeps happening. Called per swing.
    func tallyFaults(_ faults: [SwingFault]) {
        guard !faults.isEmpty else { return }
        updateProfile { p in
            for f in faults { p.faultTally[f.id.rawValue, default: 0] += 1 }
        }
    }

    /// User-selected coaching frequency. Persisted across launches. Default
    /// is `everySwing` for new installs.
    private static let cadenceKey = "coaching.cadence"
    var coachingCadence: CoachingCadence = {
        let raw = UserDefaults.standard.object(forKey: FeedbackOrchestrator.cadenceKey) as? Int
        return CoachingCadence(rawValue: raw ?? 1) ?? .everySwing
    }() {
        didSet {
            UserDefaults.standard.set(coachingCadence.rawValue, forKey: Self.cadenceKey)
            // Switching to .off mid-utterance should cut current speech too.
            if coachingCadence == .off { tts.stop() }
        }
    }

    let cloud: CloudLLMService?
    let rules = RuleTemplateService()
    let tts = TTSService()
    /// Live coaching pipeline state. Owned here so the per-swing flow has a
    /// single place to read streaks/focus from across views.
    let coach = SessionCoach()
    let directiveTemplate = DirectiveTemplate()
    let annotator = SwingAnnotator()
    let archive = SwingArchive()
    /// Field-capture mode: keep every clip + write ball sidecars — range
    /// test sessions are the data flywheel. Toggle lives in 我的页; also
    /// forced on by launch env FIELDCAPTURE=1 (automation).
    static let fieldCaptureKey = "fieldCaptureMode"
    var fieldCaptureMode: Bool {
        get {
            UserDefaults.standard.bool(forKey: Self.fieldCaptureKey)
                || ProcessInfo.processInfo.environment["FIELDCAPTURE"] == "1"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.fieldCaptureKey)
            archive.retention = newValue ? .fieldCapture : .standard
        }
    }
    /// Session start/end is user-driven via Start/End Session buttons; this
    /// guards everything coaching-related.
    let lifecycle: SessionLifecycle

    /// Live providers wired by RecordView so coachLive can attach the
    /// per-swing time range against the running session mp4.
    private var sessionVideoURLProvider: (() -> URL?)?
    private var sessionVideoStartedAtProvider: (() -> Date?)?
    /// Returns the PTS-seconds of the FIRST sample buffer written to the
    /// session mp4 (i.e. its time origin). Pose PTS values are in the same
    /// time base, so mp4-local clip time = pose_pts - this. Nil means the
    /// caller's recording source is already mp4-local (e.g. a replay file).
    private var sessionVideoFirstPTSProvider: (() -> Double?)?

    func attachCameraRecording(
        urlProvider: @escaping () -> URL?,
        startedAtProvider: @escaping () -> Date?,
        firstPTSSecondsProvider: @escaping () -> Double? = { nil }
    ) {
        sessionVideoURLProvider = urlProvider
        sessionVideoStartedAtProvider = startedAtProvider
        sessionVideoFirstPTSProvider = firstPTSSecondsProvider
    }

    init() {
        self.cloud = try? CloudLLMService()
        if cloud == nil {
            print("[FeedbackOrchestrator] no DeepSeek API key — cloud LLM disabled, "
                  + "using local rule templates only")
        }
        self.lifecycle = SessionLifecycle(archive: archive, coach: coach)
        self.lifecycle.reportGenerator = SessionReportGenerator(cloud: self.cloud)
        archive.retention = fieldCaptureMode ? .fieldCapture : .standard
        // Hand the archive its own clip-analysis pipeline. After each
        // per-swing mp4 is exported, the archive re-runs the SAME pipeline
        // Upload uses on it — clean H.264-decoded frames + Vision/YOLO
        // pose, no dependency on the lower-fidelity live tracker stream.
        // This is what makes History overlays match Upload overlays.
        let pose: PoseService = (try? YoloPoseService()) ?? VisionPoseService()
        let detector: any EventDetector =
            (try? PoseTCNEventDetector()) ?? HeuristicEventDetector()
        self.archive.clipAnalyzer = VideoAnalyzer(poseService: pose, eventDetector: detector)
    }

    /// Live mode (new path, via SessionLifecycle + SessionCoach + LLM + 2 s fallback).
    ///
    /// Pre-condition: a session has been started by the user. If not active,
    /// this is a no-op (Live tab without a session is silent).
    ///
    /// Pipeline:
    ///   1. Build AnnotatedSwing (strengths + faults + category)
    ///   2. SessionLifecycle.noteFinishedSwing → archives pose + maybe video
    ///   3. SessionCoach.ingest → CoachingDirective
    ///   4. LLM streaming with 2 s fallback → final sentence
    ///   5. TTS speak
    func coachLive(report: SwingReport, score: SwingScore) {
        dbg(tag: "coach", "coachLive ENTER poses=\(report.poseFrames.count) score=\(score.total)")
        guard lifecycle.phase == .active else {
            dbg(.warn, tag: "coach", "skip — phase=\(lifecycle.phase)")
            return
        }
        let swingIdx = (lifecycle.swingsThisSession) + 1
        let annotated = annotator.annotate(
            report: report,
            score: score,
            swingNumber: swingIdx
        )
        // Compute this swing's time range inside the active session recording
        // so SwingArchive can slice out a clip via AVAssetExportSession.
        // PoseFrame timestamps are CMSampleBuffer PTS in the camera-session
        // time base. AVAssetExportSession reads in mp4-LOCAL time (starts at
        // 0), so we subtract the recorder's first-PTS-seconds (== the mp4
        // time origin set by AVAssetWriter.startSession(atSourceTime:)).
        // If no PTS provider is wired (e.g. SessionReplay on an uploaded
        // file), pose timestamps are already mp4-local and origin = 0.
        let sessionVideoURL = sessionVideoURLProvider?() ?? report.recordingURL
        let mp4Origin = sessionVideoFirstPTSProvider?() ?? 0
        dbg(tag: "coach", "providers url=\(sessionVideoURL?.lastPathComponent ?? "nil") "
            + "mp4Origin=\(String(format: "%.3f", mp4Origin))")
        var startSec: Double?
        var endSec: Double?
        if let first = report.poseFrames.first?.timestamp,
           let last  = report.poseFrames.last?.timestamp {
            let s = CMTimeGetSeconds(first) - mp4Origin
            let e = CMTimeGetSeconds(last) - mp4Origin
            dbg(tag: "coach", "pts first=\(String(format: "%.3f", CMTimeGetSeconds(first))) "
                + "last=\(String(format: "%.3f", CMTimeGetSeconds(last))) "
                + "→ s=\(String(format: "%.3f", s)) e=\(String(format: "%.3f", e))")
            if s.isFinite, e.isFinite, e > s {
                startSec = max(0, s - 0.5)
                endSec   = e + 0.5
            }
        }
        dbg(tag: "coach", "→ archive range=[\(startSec.map { String(format: "%.2f", $0) } ?? "?")..\(endSec.map { String(format: "%.2f", $0) } ?? "?")]")
        _ = lifecycle.noteFinishedSwing(
            annotated: annotated,
            poseFrames: report.poseFrames,
            sourceVideoURL: sessionVideoURL,
            videoStartSeconds: startSec,
            videoEndSeconds: endSec
        )
        // Fold this swing's faults into the rolling tally so session-focus
        // suggestions keep learning what actually recurs.
        tallyFaults(score.faults)

        // Coach state-tracking (streaks, focus locks) runs every swing
        // regardless of cadence — only the LLM + TTS path below is gated.
        let directive = coach.ingest(score: score)
        let context = coach.contextSnapshot()
        dbg(tag: "coach", "directive: \(directive)")

        // CADENCE gate. Off → silent + no LLM cost. Every Nth → skip the
        // non-Nth swings entirely (LLM AND TTS). Archive already done above
        // so skipped swings still show up in History.
        let cadence = coachingCadence
        let swingNum = coach.state.swings.count
        if cadence == .off {
            dbg(tag: "coach", "cadence=off — skip LLM+TTS (still archived)")
            currentResponse = nil
            isLoading = false
            return
        }
        if cadence.rawValue > 1, swingNum % cadence.rawValue != 0 {
            dbg(tag: "coach",
                "cadence-skip swing #\(swingNum) (every \(cadence.rawValue))")
            currentResponse = nil
            isLoading = false
            return
        }

        // If directive says "don't speak", do nothing further.
        guard directive.shouldSpeak else {
            dbg(.warn, tag: "coach", "directive silent — no TTS")
            return
        }
        let fallback = directiveTemplate.sentence(for: directive, swingIndex: swingIdx)
        isLoading = true
        currentResponse = FeedbackResponse(summary: "", eventTips: [], source: .cloud)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = Date()
            let line: String
            if let cloud = self.cloud {
                line = await cloud.requestCoachingLineWithFallback(
                    directive: directive,
                    context: context,
                    fallback: fallback,
                    firstByteDeadlineSeconds: 2.0,
                    onPartial: { [weak self] partial in
                        guard let self else { return }
                        self.currentResponse = FeedbackResponse(
                            summary: partial,
                            eventTips: [],
                            source: .cloud
                        )
                    }
                )
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                dbg(tag: "coach", "line ready in \(ms)ms: \(line)")
            } else {
                line = fallback
                dbg(.warn, tag: "coach", "no cloud — using fallback: \(line)")
            }
            self.currentResponse = FeedbackResponse(
                summary: line,
                eventTips: [],
                source: self.cloud != nil ? .cloud : .template
            )
            self.isLoading = false
            if !line.isEmpty {
                dbg(tag: "coach", "→ TTS speakStreaming")
                self.tts.speakStreaming(line)
            } else {
                dbg(.warn, tag: "coach", "empty line — nothing to speak (directive=\(directive))")
            }
        }
    }

    /// Legacy: full LLM round-trip on the full swing payload, voice on.
    /// Kept for fallback / Upload-mode parity but the live path should call
    /// `coachLive(score:)` instead.
    func generateAndSpeak(report: SwingReport) {
        generate(report: report, speak: true, mode: .live)
    }

    /// Upload mode: rule-based diagnosis → ranked faults → deterministic tips +
    /// LLM-polished (qualitative, no-numbers) summary. No TTS.
    ///
    /// This replaces the old path that fed raw metrics to the LLM and let it
    /// free-form (which produced "X-factor is 11.6°, should be ~90°" — numbers,
    /// jargon, and judgments that contradicted our thresholds). Now the SAME
    /// `SwingFaultDetector` the live path uses runs here too, so Upload and Live
    /// agree; the LLM only phrases the already-ranked root cause.
    func generateSilently(report: SwingReport) {
        currentResponse = nil
        lastError = nil
        isLoading = true

        let score = SwingScorer().score(report: report)
        let faults = score.faults                       // ranked, root-first
        let tips = faults.map { faultTip($0, report: report) }
        let descs = faults.map { faultDescription($0) }
        lastScore = score
        lastDynamics = report.dynamics
        // Log the raw rule output to the dbg console too, so it's visible even
        // without the debug card.
        dbg(tag: "diag", "rule faults (ranked): " + (faults.isEmpty ? "none" :
            faults.map { "\($0.id.rawValue)[sev=\(String(format: "%.2f", $0.severity)) "
                + "conf=\(String(format: "%.2f", $0.confidence ?? 0))]" }.joined(separator: ", ")))

        Task { @MainActor [weak self] in
            guard let self else { return }
            var summary: String
            if let cloud = self.cloud {
                self.currentResponse = FeedbackResponse(summary: "", eventTips: tips, source: .cloud)
                do {
                    summary = try await cloud.requestQualitativeSummary(
                        faultDescriptions: descs,
                        onSummaryUpdate: { [weak self] partial in
                            self?.currentResponse = FeedbackResponse(
                                summary: partial, eventTips: tips, source: .cloud)
                        }
                    )
                } catch {
                    print("[FeedbackOrchestrator] qualitative summary failed: \(error.localizedDescription)")
                    self.lastError = "Cloud failed, using local summary"
                    summary = self.localSummary(faults: faults)
                }
            } else {
                summary = self.localSummary(faults: faults)
            }
            self.currentResponse = FeedbackResponse(
                summary: summary,
                eventTips: tips,
                source: self.cloud != nil ? .cloud : .template
            )
            self.isLoading = false
        }
    }

    /// Qualitative severity bucket — no raw numbers leak to the user.
    private func severityWord(_ s: Double) -> String {
        if s >= 0.7 { return "significant" }
        if s >= 0.4 { return "noticeable" }
        return "minor"
    }

    /// Build a deterministic tip straight from a detected fault (label + fix +
    /// anchor frame + causal chain). No LLM, no numbers — the fix text lives on
    /// SwingFaultID. `cause` carries the severity + phase + "caused by" so the
    /// UI can show the relationship.
    private func faultTip(_ f: SwingFault, report: SwingReport) -> FeedbackTip {
        let phase = f.anchorEvent?.displayName
        let frame = f.anchorEvent.flatMap { report.events.frame(for: $0) }
        let caused = (f.causedBy ?? []).map { $0.label.lowercased() }
        var cause = "\(severityWord(f.severity).capitalized)\(phase.map { " at \($0)" } ?? "")"
        if !caused.isEmpty { cause += " — likely from \(caused.joined(separator: " + "))" }
        if (f.confidence ?? 1) < FaultThresholds.default.tentativeConfidence { cause += " (tentative)" }
        return FeedbackTip(
            event: phase,
            userFrame: frame,
            metric: f.id.anchorMetric,
            tip: f.id.plainLabel,
            cause: cause,
            fix: f.id.fix,
            drill: nil
        )
    }

    /// One-line fault description for the LLM polisher — qualitative severity +
    /// causal role + "caused by" chain + the canned fix. Deliberately carries
    /// NO angle/number so the LLM can't parrot a measurement, but DOES carry the
    /// full picture (all faults + relationships) so the coach can reason about
    /// root vs symptom.
    private func faultDescription(_ f: SwingFault) -> String {
        let phase = f.anchorEvent.map { " at \($0.displayName)" } ?? ""
        let role: String
        switch f.id.layer {
        case .root:    role = "root cause"
        case .mid:     role = "contributing factor"
        case .symptom: role = "symptom"
        }
        let tentative = (f.confidence ?? 1) < FaultThresholds.default.tentativeConfidence
            ? ", tentative" : ""
        let caused = (f.causedBy ?? []).map { $0.plainLabel.lowercased() }
        let causedStr = caused.isEmpty ? "" : ", likely caused by \(caused.joined(separator: " + "))"
        return "[\(severityWord(f.severity)), \(role)\(tentative)] \(f.id.plainLabel)\(phase)\(causedStr) — fix: \(f.id.fix)"
    }

    /// Offline fallback summary (no cloud) — built from the top fault, still
    /// qualitative + encouraging.
    private func localSummary(faults: [SwingFault]) -> String {
        guard let top = faults.first else {
            return String(localized: "干净利落的一杆 — 节奏和平衡都不错，保持下去。")
        }
        return String(localized: "重点改这个：\(top.id.label)。\(top.id.fix)")
    }

    private func generate(report: SwingReport, speak: Bool, mode: CloudLLMService.Mode) {
        currentResponse = nil
        lastError = nil
        isLoading = true

        let payload = SignalsPayload(report: report)
        Task { @MainActor [weak self] in
            guard let self else { return }
            var response: FeedbackResponse
            if let cloud = self.cloud {
                let started = Date()
                // While streaming we surface a partial response so the UI can
                // start rendering text immediately. TTS still waits for the
                // final summary so it doesn't speak half-sentences.
                self.currentResponse = FeedbackResponse(summary: "", eventTips: [], source: .cloud)
                let onUpdate: @MainActor (String) -> Void = { [weak self] partial in
                    guard let self else { return }
                    self.currentResponse = FeedbackResponse(
                        summary: partial,
                        eventTips: [],
                        source: .cloud
                    )
                }
                do {
                    response = try await cloud.requestStreaming(
                        signals: payload,
                        mode: mode,
                        onSummaryUpdate: onUpdate
                    )
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    print("[FeedbackOrchestrator] cloud LLM (\(mode)) ok in \(ms)ms · \(response.summary.count) chars")
                } catch {
                    print("[FeedbackOrchestrator] cloud failed: \(error.localizedDescription)")
                    self.lastError = "Cloud failed, fell back to local templates (\(error.localizedDescription))"
                    response = self.rules.feedback(report: report)
                }
            } else {
                print("[FeedbackOrchestrator] using local rule templates (no API key)")
                response = self.rules.feedback(report: report)
            }
            self.currentResponse = response
            self.isLoading = false
            if speak {
                self.tts.speakStreaming(response.summary)
            }
        }
    }

    func stopSpeaking() { tts.stop() }

    /// Clear the feedback card / current response so a fresh session starts
    /// with a clean HUD. Call when a new session begins.
    func clearTransientState() {
        currentResponse = nil
        lastError = nil
        isLoading = false
    }
}

// MARK: - User profile (local, no cloud)

/// Lightweight per-user profile. Stored locally as JSON. Body fields beyond
/// handedness are kept for the future P3 body-type templates (not used yet).
/// `inferredLevel` is INTERNAL — never surfaced to the user.
struct UserProfile: Codable, Sendable {
    var onboarded: Bool = false
    var handedness: String = "right"      // "left" | "right"
    var heightCm: Double? = nil           // stored for P3, unused now
    var flexibility: String? = nil        // stored for P3, unused now
    var inferredLevel: String = "beginner"   // beginner | intermediate | advanced — INTERNAL
    /// Ranked fault rawValues from onboarding — seed for session focus suggestions.
    var focusCandidates: [String] = []
    /// Rolling count of each fault across analyzed swings — sharpens suggestions.
    var faultTally: [String: Int] = [:]
}

/// Disk-backed store for the single local UserProfile.
enum UserProfileStore {
    private static var url: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("user_profile.json")
    }
    static func load() -> UserProfile {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(UserProfile.self, from: data)
        else { return UserProfile() }
        return p
    }
    static func save(_ profile: UserProfile) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(profile) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
