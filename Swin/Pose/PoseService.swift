import CoreMedia
import Foundation
import ImageIO

enum CameraPosition: Sendable {
    case back, front
}

enum CameraOrientation: Sendable {
    case backPortrait
    case frontPortrait

    static func from(_ position: CameraPosition) -> CameraOrientation {
        position == .back ? .backPortrait : .frontPortrait
    }
}

/// 17 COCO keypoints in normalized image coords with upper-left origin.
/// Order: nose, L/R eye, L/R ear, L/R shoulder, L/R elbow, L/R wrist,
/// L/R hip, L/R knee, L/R ankle.
///
/// Normalization convention: each axis is divided by its own dimension, so
/// keypoints live in [0,1]×[0,1] of the oriented frame. This is the standard
/// Vision convention; YoloPoseService now matches it. The renderer can just
/// multiply by the displayed video's width / height to land on the right pixel.
///
/// PoseTCN's feature extractor needs distances that share units. We pass
/// `imageAspect` (= oriented W/H) so the extractor can multiply kp.x by aspect
/// to recover iso (pixel/H) units before computing torso scale.
///
/// `isoNormalized` is kept for backward compatibility decoding OLD on-disk
/// dumps that were written in iso convention. Live code paths set
/// `isoNormalized: false` and rely on `imageAspect`.
struct PoseFrame: Sendable {
    var timestamp: CMTime
    var keypoints: [SIMD2<Float>]
    var confidences: [Float]
    var isoNormalized: Bool = false
    /// Oriented-image aspect ratio (width / height). Defaults to 1 (square /
    /// unknown); set by pose services to the actual oriented dimensions so
    /// PoseTCN feature extraction can compensate for non-square frames.
    var imageAspect: Float = 1.0

    static let jointCount = 17

    /// Skeleton edges for overlay drawing. (a,b) joint index pairs.
    static let edges: [(Int, Int)] = [
        (5, 7), (7, 9),          // left arm
        (6, 8), (8, 10),         // right arm
        (5, 6),                  // shoulders
        (5, 11), (6, 12),        // torso sides
        (11, 12),                // hips
        (11, 13), (13, 15),      // left leg
        (12, 14), (14, 16),      // right leg
        (0, 1), (0, 2),          // nose ↔ eyes
        (1, 3), (2, 4),          // eyes ↔ ears
    ]
}

protocol PoseService: AnyObject {
    /// Most recently published pose (live path). Updated on the main thread.
    var latestPose: PoseFrame? { get }

    /// Live path: submit a buffer for inference, return immediately, drop if busy.
    /// Concrete impls publish results via their own observable `latestPose` and
    /// invoke `onPoseUpdate` on the main thread.
    func submit(_ buffer: CMSampleBuffer, orientation: CameraOrientation)

    /// Batch path: synchronously run inference on the calling thread and return
    /// the pose. No drop-if-busy, no callbacks. Used by VideoAnalyzer for
    /// uploaded videos with arbitrary orientation.
    func extractSync(_ buffer: CMSampleBuffer, cgOrientation: CGImagePropertyOrientation) -> PoseFrame?

    var onPoseUpdate: ((PoseFrame) -> Void)? { get set }

    /// Force-clear any in-flight guard (e.g. `isProcessing` for YOLO). Called
    /// by CameraService when restarting a session after a backgrounding —
    /// the previous inference may not have fired its `defer` cleanup.
    func forceClearBusy()
}

extension PoseService {
    func forceClearBusy() {}

    /// Convenience wrapper around `extractSync(_:cgOrientation:)` for callers
    /// that already think in CameraOrientation (live camera path).
    func extractSync(_ buffer: CMSampleBuffer, orientation: CameraOrientation) -> PoseFrame? {
        let cg: CGImagePropertyOrientation =
            (orientation == .backPortrait) ? .right : .leftMirrored
        return extractSync(buffer, cgOrientation: cg)
    }
}
