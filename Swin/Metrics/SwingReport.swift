import CoreGraphics
import CoreMedia
import Foundation

/// Camera angle the swing was shot from. The user picks this on upload so we
/// know how to read the 2D projection: face-on shows X-factor / head stability
/// / weight shift clearly; down-the-line shows swing path / posture / plane.
/// Each fault has a `bestViewpoint`; when the clip's viewpoint doesn't match,
/// that fault's read is less reliable (we can flag "better seen from …").
enum Viewpoint: String, Codable, Sendable, CaseIterable {
    case faceOn = "face_on"
    case downTheLine = "down_the_line"
    var label: String { self == .faceOn ? String(localized: "正面") : String(localized: "侧面") }
    var hint: String {
        self == .faceOn
            ? String(localized: "手机在你正前方，正对你的胸口。")
            : String(localized: "手机在你身后，顺着目标线方向看过去。")
    }
}

struct SwingReport: Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let recordingURL: URL?
    let poseFrames: [PoseFrame]
    let events: SwingEvents
    let metrics: SwingMetrics?
    let perEvent: [PerEventMetrics]
    /// Multi-frame trajectory / interval metrics (head stability, hip drift,
    /// over-the-top, brace, finish balance…). Nil for old reports built before
    /// v0.2; fault detection degrades gracefully when fields are missing.
    let dynamics: SwingDynamics?
    /// Post-impact ball trajectory detected via VNDetectTrajectoriesRequest.
    /// Nil if no recording URL was available, detection failed, or the ball
    /// was not visible / went out of frame too fast.
    let ballTrajectory: BallTrajectory?
    /// Metric ball flight (speed/launch/carry) solved from 2D detections +
    /// camera intrinsics. Device recordings only (needs intrinsics on disk).
    let ballFlight: BallFlight?
    /// Clubhead track from the distilled on-device club detector. Sparse
    /// anchor points (see ClubTrack docs) — nil when detection found < 3
    /// confident clubheads or the pass was skipped.
    let clubTrack: ClubTrack?
    /// Pose normalization frame size — the dimensions of the video AFTER
    /// applying the preferredTransform (i.e., the orientation-corrected size
    /// that the pose extractor saw). PoseOverlay uses this to map normalized
    /// [0,1] keypoints back to view-space pixels. Defaults to 1080×1920 portrait
    /// for backward compatibility with live recordings.
    let videoSize: CGSize
    /// Camera angle the user shot this from (chosen on upload). Drives which
    /// faults/visualizations are reliable. Defaults to down-the-line.
    let viewpoint: Viewpoint

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        recordingURL: URL?,
        poseFrames: [PoseFrame],
        events: SwingEvents,
        metrics: SwingMetrics?,
        perEvent: [PerEventMetrics] = [],
        dynamics: SwingDynamics? = nil,
        ballTrajectory: BallTrajectory? = nil,
        ballFlight: BallFlight? = nil,
        clubTrack: ClubTrack? = nil,
        videoSize: CGSize = CGSize(width: 1080, height: 1920),
        viewpoint: Viewpoint = .downTheLine
    ) {
        self.id = id
        self.timestamp = timestamp
        self.recordingURL = recordingURL
        self.poseFrames = poseFrames
        self.events = events
        self.metrics = metrics
        self.perEvent = perEvent
        self.dynamics = dynamics
        self.ballTrajectory = ballTrajectory
        self.ballFlight = ballFlight
        self.clubTrack = clubTrack
        self.videoSize = videoSize
        self.viewpoint = viewpoint
    }
}

// MARK: - frame ↔ video-time mapping

extension SwingReport {
    /// Inferred padding (seconds) between the start of the saved video clip
    /// and the first pose. Live-mode clips are trimmed with ±0.5 s runway
    /// around the swing (see `FeedbackOrchestrator.coachLive`), so the first
    /// pose lands ~0.5 s into the file. Upload-mode clips have no padding so
    /// this returns 0. Computed dynamically from the gap between the clip's
    /// duration and the actual span of pose timestamps.
    func clipPaddingSeconds(duration: Double) -> Double {
        guard poseFrames.count > 1, duration > 0 else { return 0 }
        let first = CMTimeGetSeconds(poseFrames.first!.timestamp)
        let last  = CMTimeGetSeconds(poseFrames.last!.timestamp)
        let poseSpan = last - first
        guard poseSpan.isFinite, poseSpan > 0 else { return 0 }
        return max(0, (duration - poseSpan) / 2)
    }

    /// Video clip time corresponding to a pose-frame index. Uses the pose's
    /// own timestamp so non-uniform sampling (rare) maps correctly. The
    /// ±padding inferred above is added so event ticks line up with where
    /// the body actually appears in the saved mp4.
    func clipTime(forFrame frame: Int, duration: Double) -> Double {
        guard poseFrames.count > 1, duration > 0 else { return 0 }
        guard frame >= 0, frame < poseFrames.count else {
            return frame < 0 ? 0 : duration
        }
        let first = CMTimeGetSeconds(poseFrames.first!.timestamp)
        let now   = CMTimeGetSeconds(poseFrames[frame].timestamp)
        let padding = clipPaddingSeconds(duration: duration)
        return max(0, min(duration, padding + (now - first)))
    }

    /// Pose-frame index that matches a given video clip time. Inverse of
    /// `clipTime(forFrame:duration:)`. Linear scan — fine for ~hundreds
    /// of frames.
    func frame(forClipTime time: Double, duration: Double) -> Int {
        guard poseFrames.count > 1 else { return 0 }
        let padding = clipPaddingSeconds(duration: duration)
        let first = CMTimeGetSeconds(poseFrames.first!.timestamp)
        let targetPoseT = first + max(0, time - padding)
        var bestIdx = 0
        var bestDiff = Double.infinity
        for (i, p) in poseFrames.enumerated() {
            let d = abs(CMTimeGetSeconds(p.timestamp) - targetPoseT)
            if d < bestDiff { bestDiff = d; bestIdx = i }
        }
        return bestIdx
    }
}
