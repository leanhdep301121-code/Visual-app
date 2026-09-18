import SwiftUI

/// Ball-flight trace over a video frame — Toptracer-style warm glow ribbon
/// (splined, tapered, comet head). `visibleUpTo` is seconds since impact
/// (the trajectory points' own time base): nothing shows before impact, the
/// trace draws with the flight, and the full arc stays afterwards.
/// Coords are normalized [0,1] with top-left origin.
struct BallTrajectoryOverlay: View {
    let trajectory: BallTrajectory
    /// Seconds-since-impact up to which the trace is revealed. nil = full.
    var visibleUpTo: Double? = nil

    private static let amber = Color(red: 1.0, green: 0.42, blue: 0.18)

    var body: some View {
        Canvas { ctx, size in
            // Fitted arc only when available (tee → apex → landing, smooth —
            // matches the offline render). Mixing the raw detection stub in
            // adds jitter the fit already explains. Raw points are the
            // fallback for reports made before full-arc prediction.
            // Enforce "nothing before impact" (t < 0): the fit's launch can sit
            // a hair before impact, and a polluted obs head can push it earlier
            // — either way the tracer must not draw during address/downswing.
            let raw = (trajectory.predictedPoints?.count ?? 0) > 2
                ? trajectory.predictedPoints! : trajectory.points
            let samples: [Tracer.Sample] = raw
                .filter { $0.timeOffsetSeconds >= 0 }
                .map { Tracer.Sample(x: CGFloat($0.x), y: CGFloat($0.y), t: $0.timeOffsetSeconds) }
            Tracer.draw(ctx, size: size,
                        samples: samples,
                        visibleUpTo: visibleUpTo,
                        style: .init(glow: Self.amber, coreWidthRatio: 0.005),
                        gapBreak: 0.6)

            // Landing pulse: once the reveal clears the end of the arc, one
            // expanding fading ring at the landing point (0.9 s).
            if let cut = visibleUpTo, let last = samples.last, cut >= last.t {
                let age = cut - last.t
                if age < 0.9 {
                    let p = CGFloat(age / 0.9)
                    let c = CGPoint(x: last.x * size.width, y: last.y * size.height)
                    let r = size.width * (0.012 + 0.055 * p)
                    ctx.stroke(
                        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r,
                                               width: r * 2, height: r * 2)),
                        with: .color(Self.amber.opacity(0.85 * (1 - Double(p)))),
                        style: StrokeStyle(lineWidth: max(1.5, size.width * 0.004)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
