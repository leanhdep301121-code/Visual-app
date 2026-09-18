import CoreMedia
import Foundation

/// Result of running `BallTrajectoryDetector` over the post-impact frames of a swing.
/// Coordinates are normalized image-space [0, 1] with origin top-left.
struct BallTrajectory: Codable, Sendable {
    /// Quadratic coefficients y = a*x² + b*x + c (normalized image coords).
    /// Vision returns these with the lower-left origin convention; we flip
    /// before storing so a > 0 means "trajectory arcs upward in our top-left
    /// coordinate system". Larger |a| = tighter arc.
    let a: Float
    let b: Float
    let c: Float

    /// Sampled trajectory points along x (sorted by time / x). Mutable so the
    /// analyzer can merge multi-detector observations (YOLO + motion pass).
    var points: [Point]
    /// Detection confidence (0…1) from Vision's request.
    let confidence: Float
    /// Frame index in the swing's pose stream where Impact happened — used to
    /// align the trajectory in time when overlaying.
    let impactFrameIndex: Int
    /// Number of frames the detection window spanned.
    let windowFrameCount: Int
    /// Physics-projected continuation of the flight past the observed stub
    /// (BallFlightSolver forward integration). Nil on old reports / failed
    /// fits — overlays then draw the observed points only.
    var predictedPoints: [Point]? = nil
    /// Absolute media time (seconds) of points[0] — lets independent
    /// detector passes (YOLO / motion launch witness) align time bases.
    /// Nil on old archives.
    var firstObsMediaTime: Double? = nil

    struct Point: Codable, Sendable, Hashable {
        let x: Float
        let y: Float
        /// Seconds since impact, for later velocity estimation.
        let timeOffsetSeconds: Double
    }

    /// Highest the ball reached in this trajectory (smallest y in top-left coord).
    var apexY: Float? {
        points.map(\.y).min()
    }

    /// Horizontal travel (last.x - first.x).
    var horizontalSpan: Float? {
        guard let first = points.first, let last = points.last else { return nil }
        return abs(last.x - first.x)
    }
}
