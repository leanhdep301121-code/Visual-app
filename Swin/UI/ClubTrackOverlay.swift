import SwiftUI

/// Clubhead track over a video frame — broadcast tracer look (splined,
/// tapered triple-layer glow, comet head). `visibleUpTo` is a media time in
/// the clip's own base: the arc draws on in sync with playback and stays
/// once the swing completes. Coords normalized [0,1] top-left.
struct ClubTrackOverlay: View {
    let track: ClubTrack
    /// Clip media time up to which the trace is revealed. nil = full arc.
    var visibleUpTo: Double? = nil

    private static let cyan = Color(red: 0.35, green: 0.9, blue: 1.0)

    var body: some View {
        Canvas { ctx, size in
            Tracer.draw(ctx, size: size,
                        samples: track.points.map {
                            .init(x: CGFloat($0.x), y: CGFloat($0.y), t: $0.timeSeconds)
                        },
                        visibleUpTo: visibleUpTo,
                        style: .init(glow: Self.cyan, coreWidthRatio: 0.004))
        }
        .allowsHitTesting(false)
    }
}
