import Foundation
import Observation

@Observable
final class SwingRecorder: @unchecked Sendable {
    private(set) var report: SwingReport?
    /// Latest swing's computed score (faults + sub-scores + total 0-100).
    /// Always set in lockstep with `report`; nil before the first swing finishes.
    private(set) var score: SwingScore?

    /// Swap to a `PoseTCNEventDetector` once `PoseTCN.mlpackage` ships.
    var eventDetector: any EventDetector = HeuristicEventDetector()
    /// Session camera angle — set by RecordView when a session starts, so live
    /// swing metrics use viewpoint-aware signs + the viewpoint hard-filter.
    var viewpoint: Viewpoint = .downTheLine
    /// Session handedness — set by RecordView from the onboarding choice. The
    /// live event detector's auto-handedness is unreliable and a wrong guess
    /// mirrors the whole overlay + flips the metric signs, so the user's choice
    /// overrides it (same as Upload forces handedness through the analyzer).
    var handedness: Handedness = .right

    private let scorer = SwingScorer()
    private let lock = NSLock()
    private var poseFrames: [PoseFrame] = []
    private var isCapturing = false

    func start() {
        lock.lock(); defer { lock.unlock() }
        poseFrames.removeAll(keepingCapacity: true)
        isCapturing = true
        DispatchQueue.main.async { self.report = nil }
    }

    func append(_ pose: PoseFrame) {
        lock.lock(); defer { lock.unlock() }
        guard isCapturing else { return }
        poseFrames.append(pose)
    }

    func stop(recordingURL: URL) {
        lock.lock()
        isCapturing = false
        let frames = poseFrames
        lock.unlock()
        let report = analyze(frames: frames, recordingURL: recordingURL)
        let score = scorer.score(report: report)
        DispatchQueue.main.async {
            self.report = report
            self.score = score
        }
    }

    /// Run event detection + metrics on a pose sequence and publish as the latest report.
    /// Used by SwingDetector for auto-detected swings (no recordingURL).
    ///
    /// If `events` is supplied (LiveSwingTracker already decoded them in real-time),
    /// skip the post-hoc detection pass.
    ///
    /// Returns the freshly-built (report, score) so callers can route them
    /// straight to the live coaching pipeline without going through the
    /// @Observable slots — that slot is single-valued and gets overwritten if
    /// two swings emit before the consumer's onChange handler runs.
    @discardableResult
    func publish(autoDetectedPoses frames: [PoseFrame],
                 events: SwingEvents? = nil) -> (SwingReport, SwingScore) {
        let report = analyze(frames: frames, recordingURL: nil, preDecodedEvents: events)
        let score = scorer.score(report: report)
        DispatchQueue.main.async {
            self.report = report
            self.score = score
        }
        return (report, score)
    }

    private func analyze(frames: [PoseFrame], recordingURL: URL?, preDecodedEvents: SwingEvents? = nil) -> SwingReport {
        let detected = preDecodedEvents ?? eventDetector.detect(frames)
        // Force the session's handedness over whatever auto-detection guessed —
        // a wrong guess mirrors the overlay + flips the toward-target signs.
        let events = SwingEvents(frames: detected.frames, handedness: handedness)
        let calc = MetricsCalculator()
        let metrics = calc.compute(poses: frames, events: events)
        let perEvent = calc.computePerEvent(poses: frames, events: events)
        let dynamics = calc.computeDynamics(poses: frames, events: events, viewpoint: viewpoint)
        return SwingReport(
            recordingURL: recordingURL,
            poseFrames: frames,
            events: events,
            metrics: metrics,
            perEvent: perEvent,
            dynamics: dynamics,
            viewpoint: viewpoint
        )
    }
}
