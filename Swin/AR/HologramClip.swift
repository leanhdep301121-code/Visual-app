import Foundation

/// A background-removed pro-swing clip: transparent PNG frame runs bundled in
/// `Resources/` (`{id}_{index4}.png`, cleaned + de-fringed offline).
///
/// Rendered by swapping pre-loaded GPU textures inside RealityKit at the
/// clip's fps (see `HologramPuppet`) — no video decode, no per-frame SwiftUI
/// redraw. HEVC-alpha `VideoMaterial` was tried and rejected: the simulator's
/// decoder fails intermittently (visible flicker + stalls).
struct HologramClip: Identifiable, Hashable {
    let id: String            // frame-name prefix, e.g. "pro_driver"
    let title: String         // user-facing label
    let frameCount: Int
    let fps: Double           // native playback rate (1× speed)
    let aspect: Float         // frame width / height
    /// Real-world height (m) of the figure plane in AR — life-size golfer.
    let realHeightMeters: Float
    /// Frame index where the club strikes the ball — triggers the shot
    /// effect (ball launch + tracer). Eyeballed per clip from the frame runs.
    let impactFrame: Int
    /// World-space launch direction of the shot (unit-ish, y added by physics).
    /// DTL clips fire away from the camera; face-on fires screen-left.
    let launchDirection: SIMD3<Float>

    /// Frames matted with RobustVideoMatting (resnet50, high internal res) +
    /// foot-anchor stabilization (scratchpad rvm_pipeline2.py). `pro_dtl`
    /// comes from a static-tripod 60 fps source (Feishu raw library), so the
    /// temporal-median club recovery runs too — full club through the swing.
    /// Panning sources (faceon / tiger) are RVM-only: club shows when sharp.
    /// `pro_driver` stays out: no HD source (old frames remain for
    /// ProSilhouetteOverlay only).
    static let all: [HologramClip] = [
        HologramClip(id: "pro_dtl", title: "Pro · Down-the-line",
                     frameCount: 111, fps: 30, aspect: 414.0 / 640.0, realHeightMeters: 1.9,
                     impactFrame: 88, launchDirection: [0.06, 0, -1]),
        HologramClip(id: "pro_faceon", title: "Pro · Face-on",
                     frameCount: 47, fps: 30, aspect: 538.0 / 640.0, realHeightMeters: 1.9,
                     impactFrame: 31, launchDirection: [-1, 0, -0.18]),
        HologramClip(id: "tiger_driver", title: "Tiger · Driver",
                     frameCount: 102, fps: 20, aspect: 422.0 / 640.0, realHeightMeters: 1.9,
                     impactFrame: 59, launchDirection: [0.06, 0, -1]),
    ]

    static var `default`: HologramClip { all[0] }

    func frameName(_ i: Int) -> String { String(format: "%@_%04d", id, i) }
}
