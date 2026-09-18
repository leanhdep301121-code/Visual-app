import SwiftUI

/// Broadcast-style tracer rendering shared by the club-track and ball-flight
/// overlays. Recipe (same family as the AR ribbon): centripetal Catmull-Rom
/// spline through the sparse anchors → Canvas strokes in three layers
/// (blurred halo → colored glow → white-hot core) with width/opacity tapering
/// toward the head, finished with a comet head. Optionally trimmed by time so
/// the trace draws on in sync with video playback (TV tracer behavior).
enum Tracer {

    struct Style {
        var glow: Color                       // brand color of the trace
        /// Core width as a FRACTION of canvas width (resolution-independent —
        /// fixed pixels looked right on 1080px offline renders but ~3× too
        /// fat on the ~390pt in-app video rect).
        var coreWidthRatio: CGFloat = 0.005
        var haloScale: CGFloat = 3.2
        var comet: Bool = true
    }

    /// A time-stamped normalized point ([0,1] top-left).
    struct Sample {
        let x: CGFloat
        let y: CGFloat
        let t: Double
    }

    // MARK: spline

    /// Centripetal Catmull-Rom through `p` (α = 0.5 — no cusps/overshoots).
    private static func catmullRom(_ p: [CGPoint], samplesPerSeg: Int = 10) -> [CGPoint] {
        guard p.count > 2 else { return p }
        var out: [CGPoint] = [p[0]]
        func tj(_ ti: CGFloat, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            ti + pow(max(hypot(b.x - a.x, b.y - a.y), 1e-5), 0.5)
        }
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            let t0: CGFloat = 0
            let t1 = tj(t0, p0, p1), t2 = tj(t1, p1, p2), t3 = tj(t2, p2, p3)
            guard t2 - t1 > 1e-6 else { continue }
            for s in 1...samplesPerSeg {
                let t = t1 + (t2 - t1) * CGFloat(s) / CGFloat(samplesPerSeg)
                func lerpP(_ a: CGPoint, _ b: CGPoint, _ ta: CGFloat, _ tb: CGFloat) -> CGPoint {
                    let f = tb - ta > 1e-6 ? (t - ta) / (tb - ta) : 0
                    return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                }
                let a1 = lerpP(p0, p1, t0, t1), a2 = lerpP(p1, p2, t1, t2), a3 = lerpP(p2, p3, t2, t3)
                let b1 = lerpP(a1, a2, t0, t2), b2 = lerpP(a2, a3, t1, t3)
                out.append(lerpP(b1, b2, t1, t2))
            }
        }
        return out
    }

    // MARK: draw

    /// Draw the trace into a Canvas context. `visibleUpTo` (same time base as
    /// the samples) trims the head for playback-synced draw-on; nil = full.
    /// Samples with time gaps > `gapBreak` split into separate strokes so a
    /// detection dropout doesn't produce a long straight chord.
    static func draw(_ ctx: GraphicsContext, size: CGSize,
                     samples: [Sample], visibleUpTo: Double?,
                     style: Style, gapBreak: Double = 0.35) {
        let visible = visibleUpTo.map { cut in samples.filter { $0.t <= cut } } ?? samples
        guard visible.count >= 2 else { return }

        // split runs on time gaps
        var runs: [[Tracer.Sample]] = []
        var cur: [Sample] = [visible[0]]
        for s in visible.dropFirst() {
            if s.t - (cur.last?.t ?? s.t) > gapBreak {
                runs.append(cur); cur = [s]
            } else {
                cur.append(s)
            }
        }
        runs.append(cur)

        // spline each run in view space, flatten to segments with a global
        // 0…1 progress driving the taper/fade
        struct Seg { let a: CGPoint; let b: CGPoint; let prog: CGFloat }
        var segs: [Seg] = []
        var splinedRuns: [[CGPoint]] = []
        for run in runs where run.count >= 2 {
            let pts = run.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            splinedRuns.append(catmullRom(pts))
        }
        let total = max(1, splinedRuns.reduce(0) { $0 + max($1.count - 1, 0) })
        var k = 0
        for run in splinedRuns {
            for i in 1..<run.count {
                k += 1
                segs.append(Seg(a: run[i - 1], b: run[i], prog: CGFloat(k) / CGFloat(total)))
            }
        }
        guard !segs.isEmpty else { return }

        let coreW = max(1.2, size.width * style.coreWidthRatio)
        // Gentle taper only — the WHOLE line stays readable (Toptracer). An
        // aggressive tail fade (0.4w/0.25a) left everything but the head
        // invisible on a small canvas over a night sky: "the arc is only
        // there for a moment" (user verdict).
        func taper(_ p: CGFloat) -> CGFloat { 0.7 + 0.3 * p }
        func fade(_ p: CGFloat) -> Double { 0.65 + 0.35 * Double(p) }
        func layer(width: @escaping (CGFloat) -> CGFloat,
                   color: @escaping (CGFloat) -> Color,
                   blur: CGFloat) {
            ctx.drawLayer { l in
                if blur > 0 { l.addFilter(.blur(radius: blur)) }
                for s in segs {
                    var seg = Path()
                    seg.move(to: s.a); seg.addLine(to: s.b)
                    l.stroke(seg, with: .color(color(s.prog)),
                             style: StrokeStyle(lineWidth: max(width(s.prog), 0.5),
                                                lineCap: .round))
                }
            }
        }
        layer(width: { coreW * style.haloScale * taper($0) },
              color: { style.glow.opacity(0.18 * fade($0)) }, blur: 4)
        layer(width: { coreW * 1.8 * taper($0) },
              color: { style.glow.opacity(0.5 * fade($0)) }, blur: 1)
        layer(width: { coreW * taper($0) },
              color: { .white.opacity(0.9 * fade($0)) }, blur: 0)

        // head: small hot dot + faint halo (Toptracer keeps the LINE as the
        // star — a big glow ball reads as cheap VFX)
        if style.comet, let head = splinedRuns.last?.last {
            let r: CGFloat = coreW * 1.1
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 3))
                l.fill(Path(ellipseIn: CGRect(x: head.x - r * 1.7, y: head.y - r * 1.7,
                                              width: r * 3.4, height: r * 3.4)),
                       with: .color(style.glow.opacity(0.4)))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(.white.opacity(0.95)))
        }
    }
}
