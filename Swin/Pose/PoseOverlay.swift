import SwiftUI

enum PoseOverlayStyle: Sendable {
    /// COCO 17 skeleton: bones + joint dots.
    case skeleton
    /// Locked Swin ghost style: 5 geometric reference lines + head circle,
    /// double-stroke (black outline + cyan inner).
    case ghost
}

struct PoseOverlay: View {
    static var didDumpDiag: Bool = false
    let pose: PoseFrame?
    var proPose: PoseFrame? = nil    // optional Pro reference registered onto user's frame
    let cameraPosition: CameraPosition
    let imageSize: CGSize    // capture buffer size after rotation: 1080×1920 portrait
    var style: PoseOverlayStyle = .skeleton
    /// Debug: extra horizontal flip on top of the default front/back mirror logic.
    /// Lets RecordView toggle a mirror test on the fly without rebuilding.
    var forceMirror: Bool = false

    private let confidenceThreshold: Float = 0.3

    var body: some View {
        GeometryReader { _ in
            Canvas { ctx, size in
                if let proPose {
                    let pts = projectedPoints(pose: proPose, viewSize: size)
                    drawProSkeleton(ctx: &ctx, pts: pts, pose: proPose)
                }
                if let pose {
                    let pts = projectedPoints(pose: pose, viewSize: size)
                    switch style {
                    case .skeleton: drawSkeleton(ctx: &ctx, pts: pts, pose: pose)
                    case .ghost:    drawGhost(ctx: &ctx, pts: pts, pose: pose)
                    }
                }
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }

    /// Render the Pro reference as a filled translucent body silhouette
    /// (torso quad + capsule limbs + filled head) registered onto the user's
    /// frame. Looks like a "ghost person" rather than a stick figure.
    private func drawProSkeleton(ctx: inout GraphicsContext, pts: [CGPoint], pose: PoseFrame) {
        let fillColor    = Color(red: 1.00, green: 0.82, blue: 0.30).opacity(0.42)
        let outlineColor = Color.black.opacity(0.55)
        let outlineW: CGFloat = 1.3

        func conf(_ idx: Int) -> Bool { pose.confidences[idx] > confidenceThreshold }

        // Need core joints to draw anything coherent
        guard conf(Joint.leftShoulder), conf(Joint.rightShoulder),
              conf(Joint.leftHip),      conf(Joint.rightHip)
        else { return }

        let shMid = CGPoint(
            x: (pts[Joint.leftShoulder].x + pts[Joint.rightShoulder].x) / 2,
            y: (pts[Joint.leftShoulder].y + pts[Joint.rightShoulder].y) / 2
        )
        let hipMid = CGPoint(
            x: (pts[Joint.leftHip].x + pts[Joint.rightHip].x) / 2,
            y: (pts[Joint.leftHip].y + pts[Joint.rightHip].y) / 2
        )
        let torsoH = max(20,
            ((shMid.x - hipMid.x) * (shMid.x - hipMid.x)
             + (shMid.y - hipMid.y) * (shMid.y - hipMid.y)).squareRoot())
        let limbW: CGFloat = max(10, torsoH * 0.22)
        let neckW: CGFloat = limbW * 0.75
        let headR: CGFloat = max(12, torsoH * 0.32)

        // Torso: filled quad with subtle outline
        var torso = Path()
        torso.move   (to: pts[Joint.leftShoulder])
        torso.addLine(to: pts[Joint.rightShoulder])
        torso.addLine(to: pts[Joint.rightHip])
        torso.addLine(to: pts[Joint.leftHip])
        torso.closeSubpath()
        ctx.fill  (torso, with: .color(fillColor))
        ctx.stroke(torso, with: .color(outlineColor),
                   style: StrokeStyle(lineWidth: outlineW, lineJoin: .round))

        // Limbs: thick round-cap strokes = capsules
        let limbs: [(Int, Int)] = [
            (Joint.leftShoulder, Joint.leftElbow),
            (Joint.leftElbow,    Joint.leftWrist),
            (Joint.rightShoulder, Joint.rightElbow),
            (Joint.rightElbow,    Joint.rightWrist),
            (Joint.leftHip,  Joint.leftKnee),
            (Joint.leftKnee, Joint.leftAnkle),
            (Joint.rightHip,  Joint.rightKnee),
            (Joint.rightKnee, Joint.rightAnkle),
        ]
        for (a, b) in limbs where conf(a) && conf(b) {
            var seg = Path()
            seg.move(to: pts[a]); seg.addLine(to: pts[b])
            ctx.stroke(seg, with: .color(outlineColor),
                       style: StrokeStyle(lineWidth: limbW + outlineW * 2, lineCap: .round))
            ctx.stroke(seg, with: .color(fillColor),
                       style: StrokeStyle(lineWidth: limbW, lineCap: .round))
        }

        // Neck capsule from shoulder-mid to nose
        if conf(Joint.nose) {
            var neck = Path()
            neck.move(to: shMid); neck.addLine(to: pts[Joint.nose])
            ctx.stroke(neck, with: .color(outlineColor),
                       style: StrokeStyle(lineWidth: neckW + outlineW * 2, lineCap: .round))
            ctx.stroke(neck, with: .color(fillColor),
                       style: StrokeStyle(lineWidth: neckW, lineCap: .round))

            // Head: filled circle
            let head = CGRect(x: pts[Joint.nose].x - headR, y: pts[Joint.nose].y - headR,
                              width: headR * 2, height: headR * 2)
            let headPath = Path(ellipseIn: head)
            ctx.fill  (headPath, with: .color(fillColor))
            ctx.stroke(headPath, with: .color(outlineColor),
                       style: StrokeStyle(lineWidth: outlineW))
        }
    }

    private func drawSkeleton(ctx: inout GraphicsContext, pts: [CGPoint], pose: PoseFrame) {
        var bonePath = Path()
        for (a, b) in PoseFrame.edges {
            guard pose.confidences[a] > confidenceThreshold,
                  pose.confidences[b] > confidenceThreshold else { continue }
            bonePath.move(to: pts[a])
            bonePath.addLine(to: pts[b])
        }
        ctx.stroke(bonePath, with: .color(.cyan.opacity(0.9)), lineWidth: 3)
        for (i, p) in pts.enumerated() {
            guard pose.confidences[i] > confidenceThreshold else { continue }
            let r: CGFloat = 4.5
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(.white))
        }
    }

    /// 5 reference lines + head circle, double-stroke (black 4pt outline + cyan 2pt inner).
    /// Lines: spine, shoulder, hip, stance, lead-arm (proxy for swing plane).
    private func drawGhost(ctx: inout GraphicsContext, pts: [CGPoint], pose: PoseFrame) {
        func mid(_ a: Int, _ b: Int) -> CGPoint {
            CGPoint(x: (pts[a].x + pts[b].x) / 2, y: (pts[a].y + pts[b].y) / 2)
        }
        func conf(_ a: Int, _ b: Int) -> Bool {
            pose.confidences[a] > confidenceThreshold && pose.confidences[b] > confidenceThreshold
        }

        var path = Path()

        if conf(Joint.leftHip, Joint.rightHip) && conf(Joint.leftShoulder, Joint.rightShoulder) {
            path.move(to: mid(Joint.leftHip, Joint.rightHip))
            path.addLine(to: mid(Joint.leftShoulder, Joint.rightShoulder))
        }
        if conf(Joint.leftShoulder, Joint.rightShoulder) {
            path.move(to: pts[Joint.leftShoulder]); path.addLine(to: pts[Joint.rightShoulder])
        }
        if conf(Joint.leftHip, Joint.rightHip) {
            path.move(to: pts[Joint.leftHip]); path.addLine(to: pts[Joint.rightHip])
        }
        if conf(Joint.leftAnkle, Joint.rightAnkle) {
            path.move(to: pts[Joint.leftAnkle]); path.addLine(to: pts[Joint.rightAnkle])
        }
        // Lead arm proxy for swing plane: shoulder → wrist (lead = left for right-handed)
        if conf(Joint.leftShoulder, Joint.leftWrist) {
            path.move(to: pts[Joint.leftShoulder]); path.addLine(to: pts[Joint.leftWrist])
        }

        // Double-stroke: black outline first, cyan inner second
        ctx.stroke(path, with: .color(.black.opacity(0.85)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        ctx.stroke(path, with: .color(.cyan), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

        // Head circle: centered on nose, radius proportional to torso height (hip-mid → shoulder-mid distance)
        if pose.confidences[Joint.nose] > confidenceThreshold,
           conf(Joint.leftHip, Joint.rightHip),
           conf(Joint.leftShoulder, Joint.rightShoulder) {
            let hipMid = mid(Joint.leftHip, Joint.rightHip)
            let shMid = mid(Joint.leftShoulder, Joint.rightShoulder)
            let torsoH = hypot(shMid.x - hipMid.x, shMid.y - hipMid.y)
            let r = max(18, torsoH * 0.32)
            let head = CGRect(x: pts[Joint.nose].x - r, y: pts[Joint.nose].y - r, width: r * 2, height: r * 2)
            let circle = Path(ellipseIn: head)
            ctx.stroke(circle, with: .color(.black.opacity(0.85)), style: StrokeStyle(lineWidth: 5))
            ctx.stroke(circle, with: .color(.cyan), style: StrokeStyle(lineWidth: 2.5))
        }
    }

    /// Map anisotropic-normalized keypoints (kp.x = pixel_x / orientedW,
    /// kp.y = pixel_y / orientedH) → view-space points, matching the displayed
    /// video's aspect-fit / aspect-fill rect. Horizontal mirroring is applied
    /// for the front camera so the overlay matches the auto-mirrored preview.
    ///
    /// Legacy iso-normalized poses (kp.x in [0, W/H], both axes / H) — only
    /// produced by old on-disk dumps before YOLO was switched to anisotropic —
    /// are converted to aniso by multiplying kp.x by H/W on the fly.
    private func projectedPoints(pose: PoseFrame, viewSize: CGSize) -> [CGPoint] {
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let dispW = imageSize.width * scale
        let dispH = imageSize.height * scale
        let xOffset = (viewSize.width - dispW) / 2
        let yOffset = (viewSize.height - dispH) / 2
        // One-shot diagnostic — surfaces actual runtime values for a sanity
        // check. If the skeleton ever looks off again, the first hip's kp.x
        // tells us instantly whether the data is aniso (~0.5 at center) or
        // iso (~0.28 at center for portrait video).
        if !PoseOverlay.didDumpDiag {
            PoseOverlay.didDumpDiag = true
            let lhip = pose.keypoints.indices.contains(11) ? pose.keypoints[11] : .zero
            let rhip = pose.keypoints.indices.contains(12) ? pose.keypoints[12] : .zero
            print(String(format:
                "[PoseOverlay] iso=%@ aspect=%.3f imageSize=%.0fx%.0f viewSize=%.0fx%.0f " +
                "dispW=%.0f dispH=%.0f xOffset=%.1f yOffset=%.1f " +
                "L-hip=(%.3f,%.3f) R-hip=(%.3f,%.3f)",
                String(describing: pose.isoNormalized), pose.imageAspect,
                imageSize.width, imageSize.height,
                viewSize.width, viewSize.height,
                dispW, dispH, xOffset, yOffset,
                lhip.x, lhip.y, rhip.x, rhip.y))
        }
        // Front-camera preview is auto-mirrored by AVCaptureVideoPreviewLayer,
        // so we mirror the overlay to match. `forceMirror` lets the caller
        // override (useful for debugging back-camera mirror issues).
        let mirror = (cameraPosition == .front) != forceMirror
        // If the pose is legacy iso, rescale x to aniso on the fly so the
        // single render path below works for both.
        let isoToAniso = pose.isoNormalized
            ? (imageSize.height / max(1, imageSize.width)) : 1

        return pose.keypoints.map { kp in
            var nx = CGFloat(kp.x) * isoToAniso
            if mirror { nx = 1 - nx }
            return CGPoint(
                x: xOffset + nx * dispW,
                y: yOffset + CGFloat(kp.y) * dispH
            )
        }
    }
}
