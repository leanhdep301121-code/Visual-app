import SwiftUI
import UIKit

/// Overlays a frame-indexed Pro silhouette PNG on top of the user video.
///
/// **Time** is event-synced: the Pro frame is chosen by warping the user's
/// current frame through the 8 event anchors, so the Pro tracks the user's
/// playback / scrubbing / slow-motion and hits Top, Impact, etc. together.
///
/// **Space** uses a frozen *two-point* similarity (scale + rotation +
/// translation) built from the user's Address ankle-mid and shoulder-mid: the
/// Pro's feet land on the user's feet AND the Pro's shoulders land on the
/// user's shoulders, so the spine/posture overlaps instead of the shoulders
/// drifting. Because the transform is a similarity applied in each video's own
/// pixel space, the Pro keeps its native aspect (no horizontal squish from the
/// user/Pro videos having different aspect ratios). The transform is frozen at
/// Address, so the only on-screen motion is the Pro's own swing — no jitter.
struct ProSilhouetteOverlay: View {
    let pro: ProReference
    let meta: ProSilhouetteMeta
    /// Frozen two-point registration. Built once via `SwingAligner.register`.
    let reg: SwingAligner.Registration
    /// User's CURRENT pose-frame index (from `report.frame(forClipTime:…)`).
    let userFrame: Int
    /// User event frames (8). Warps `userFrame` onto the Pro timeline.
    let userEvents: [Int]
    /// Aspect (W/H) of the actual user video — MUST equal the value the
    /// VideoPlayer is laid out with, so the silhouette sits in the same rect.
    var videoAspect: CGFloat = 9.0 / 16.0
    /// Semi-transparent so the user still sees THEMSELVES through the Pro — the
    /// whole point is comparing your body against the Pro's at the same moment.
    /// The bright outline keeps the Pro readable even at low fill opacity.
    var opacity: Double = 0.5
    var showDiagnostics: Bool = false
    /// Outline color drawn AROUND the Pro cut-out (a slightly enlarged tinted
    /// silhouette behind the real photo). Keeps the actual Pro visible — you can
    /// see their body/club — while a bright rim separates them from the user
    /// even when the clothing matches. nil = no outline (raw cut-out only).
    var outline: Color? = .cyan
    /// Fill opacity of the real Pro photo. Lowered for down-the-line, where two
    /// side-on bodies overlap and a solid fill turns to mush — there we lean on
    /// the crisp outline + a very faint fill so you can still tell the two apart.
    var fillOpacity: Double = 0.62

    var body: some View {
        GeometryReader { geo in
            let fitted = fittedSize(in: geo.size, aspect: videoAspect)
            if let p = placement(fitted: fitted) {
                ZStack(alignment: .topLeading) {
                    if let img = p.image {
                        ZStack {
                            // The real Pro, semi-transparent so you still see the
                            // actual person (not just a rim) AND your own body
                            // through them. The outline ring on top keeps the
                            // edge crisp at this opacity.
                            Image(uiImage: img)
                                .resizable()
                                .frame(width: p.size.width, height: p.size.height)
                                .opacity(fillOpacity)
                            // Crisp OUTLINE ring only: an enlarged tinted
                            // silhouette with the inner body cut out (destOut),
                            // so just the EDGE is drawn. The user shows clearly
                            // through the transparent middle — the Pro is marked
                            // by a sharp rim, not a filled shape.
                            Image(uiImage: img.withRenderingMode(.alwaysTemplate))
                                .resizable().renderingMode(.template)
                                .foregroundStyle(outline ?? .cyan)
                                .frame(width: p.size.width + 5, height: p.size.height + 5)
                                .overlay {
                                    Image(uiImage: img.withRenderingMode(.alwaysTemplate))
                                        .resizable().renderingMode(.template)
                                        .frame(width: p.size.width - 3, height: p.size.height - 3)
                                        .blendMode(.destinationOut)
                                }
                                .compositingGroup()
                                .shadow(color: (outline ?? .cyan).opacity(0.7), radius: 2)
                        }
                        .scaleEffect(x: reg.mirror ? -1 : 1, y: 1)
                        .rotationEffect(.radians(p.rotation))
                        .position(x: p.center.x, y: p.center.y)
                    }
                    if showDiagnostics {
                        ForEach(Array(p.marks.enumerated()), id: \.offset) { _, m in
                            Circle().fill(Color.red).frame(width: 7, height: 7)
                                .position(x: m.x, y: m.y).allowsHitTesting(false)
                        }
                    }
                }
                .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
            }
        }
        .aspectRatio(videoAspect, contentMode: .fit)
        .allowsHitTesting(false)
    }

    private struct Placement {
        let image: UIImage?
        let size: CGSize       // rendered (pre-rotation) size, native aspect
        let center: CGPoint    // where the bbox centre lands, fitted px
        let rotation: Double   // radians
        let marks: [CGPoint]   // diagnostic: user ankle + shoulder, fitted px
    }

    private func placement(fitted: CGSize) -> Placement? {
        let proFrameIdx = SwingAligner.proFrame(
            forUserFrame: userFrame, userEvents: userEvents, proEvents: pro.events
        )
        guard proFrameIdx >= 0,
              proFrameIdx < pro.frames.count,
              proFrameIdx < meta.bboxes.count,
              meta.frameSize.count == 2,
              pro.imageSize.count == 2
        else { return nil }

        let bbox = meta.bboxes[proFrameIdx]
        guard bbox.count == 4 else { return nil }
        let resW = CGFloat(meta.frameSize[0]), resH = CGFloat(meta.frameSize[1])
        guard resW > 0, resH > 0 else { return nil }

        // A consistent "pro pixel" space (aspect = pro video) for both the
        // landmarks and the bbox, so the derived similarity is undistorted.
        let Wp = CGFloat(pro.imageSize[0]), Hp = CGFloat(pro.imageSize[1])
        guard Wp > 0, Hp > 0 else { return nil }

        // Pro landmarks → pro pixels (mirror flips x about the frame centre).
        func proPix(_ p: SIMD2<Float>) -> CGPoint {
            let xn = reg.mirror ? (1 - CGFloat(p.x)) : CGFloat(p.x)
            return CGPoint(x: xn * Wp, y: CGFloat(p.y) * Hp)
        }
        guard reg.proPts.count >= 2, reg.proPts.count == reg.userPts.count else { return nil }
        let P = reg.proPts.map(proPix)
        // User landmarks → fitted pixels (fitted aspect == user video aspect,
        // so this is an undistorted uniform scale of user pixels).
        let U = reg.userPts.map { CGPoint(x: CGFloat($0.x) * fitted.width,
                                          y: CGFloat($0.y) * fitted.height) }

        // Least-squares similarity P → U via the complex closed form:
        //   c = Σ(u'ᵢ · conj(p'ᵢ)) / Σ|p'ᵢ|²,  centred on the two centroids.
        // |c| = scale, arg(c) = rotation. Fits the whole body; for 2 points it
        // reduces to an exact pin.
        let n = CGFloat(P.count)
        let mP = CGPoint(x: P.reduce(0) { $0 + $1.x } / n, y: P.reduce(0) { $0 + $1.y } / n)
        let mU = CGPoint(x: U.reduce(0) { $0 + $1.x } / n, y: U.reduce(0) { $0 + $1.y } / n)
        var num = (re: CGFloat(0), im: CGFloat(0)), den = CGFloat(0)
        for i in 0..<P.count {
            let px = P[i].x - mP.x, py = P[i].y - mP.y
            let ux = U[i].x - mU.x, uy = U[i].y - mU.y
            num.re += ux * px + uy * py
            num.im += uy * px - ux * py
            den += px * px + py * py
        }
        guard den > 0.0001 else { return nil }
        let cx = num.re / den, cy = num.im / den
        let scale = (cx * cx + cy * cy).squareRoot()
        guard scale > 0.01, scale < 50 else { return nil }
        let rotation = atan2(cy, cx)

        func mapF(_ p: CGPoint) -> CGPoint {
            let dx = p.x - mP.x, dy = p.y - mP.y
            return CGPoint(x: cx * dx - cy * dy + mU.x,
                           y: cy * dx + cx * dy + mU.y)
        }

        // bbox in pro-normalized coords (mirror swaps/flips x).
        var x0n = CGFloat(bbox[0]) / resW, x1n = CGFloat(bbox[2]) / resW
        let y0n = CGFloat(bbox[1]) / resH, y1n = CGFloat(bbox[3]) / resH
        if reg.mirror { (x0n, x1n) = (1 - x1n, 1 - x0n) }
        guard x1n - x0n > 0.01, y1n - y0n > 0.01 else { return nil }

        // bbox in pro pixels → size (× scale, native aspect) + mapped centre.
        let bwPx = (x1n - x0n) * Wp, bhPx = (y1n - y0n) * Hp
        let size = CGSize(width: bwPx * scale, height: bhPx * scale)
        let centerPro = CGPoint(x: ((x0n + x1n) / 2) * Wp, y: ((y0n + y1n) / 2) * Hp)
        let center = mapF(centerPro)

        let imgName = String(format: "%@_%04d", pro.id, proFrameIdx)
        let image = UIImage(named: imgName)
        if image == nil { print("[ProSilhouette] missing asset \(imgName)") }
        if !Self.didDumpDiag {
            Self.didDumpDiag = true
            print(String(format:
                "[ProSilhouette] userFrame=%d proFrame=%d scale=%.3f rotDeg=%.1f mirror=%@ " +
                "size=%.0fx%.0f center=(%.0f,%.0f)",
                userFrame, proFrameIdx, scale, rotation * 180 / .pi, reg.mirror ? "Y" : "N",
                size.width, size.height, center.x, center.y))
        }

        return Placement(image: image, size: size, center: center, rotation: Double(rotation),
                         marks: U)
    }

    private static var didDumpDiag: Bool = false

    private func fittedSize(in outer: CGSize, aspect: CGFloat) -> CGSize {
        let h = min(outer.height, outer.width / max(aspect, 0.01))
        return CGSize(width: h * aspect, height: h)
    }
}
