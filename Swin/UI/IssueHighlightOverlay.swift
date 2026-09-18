import SwiftUI

/// Replaces the full skeleton + Tiger ghost overlays with a single, focused
/// highlight: at each event frame the user lands on, find the metric whose
/// value is most off and draw a red box around the related joint plus a
/// short label saying the value and the problem. Nothing else clutters the
/// frame — easier to read than a busy two-skeleton overlay.
struct IssueHighlightOverlay: View {
    let pose: PoseFrame?
    let perEvent: [PerEventMetrics]
    let events: SwingEvents
    /// Pose-frame index for the current player time, already computed by
    /// the parent using the timestamp-aware mapping (so live clips with
    /// padding around the swing align correctly).
    let currentFrame: Int
    /// The rect (in container coordinates) where the video itself is
    /// rendered. The overlay frame is the FULL container — bigger than the
    /// video — so we can place the issue label in the side letterbox.
    let videoRect: CGRect
    /// Height reserved at the video's top edge (the ball-flight data capsule
    /// lives there) so the inside-corner fallback label clears it.
    var topLeftReserved: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            if let pose,
               let issue = currentIssue(pose: pose),
               let pt = jointPoint(pose: pose, joint: issue.joint)
            {
                let placement = computePlacement(jointPt: pt, container: geo.size)
                let dotR: CGFloat = 8
                let ringR: CGFloat = 16
                ZStack(alignment: .topLeading) {
                    Circle()
                        .stroke(Color.red.opacity(0.55), lineWidth: 2)
                        .frame(width: ringR * 2, height: ringR * 2)
                        .offset(x: pt.x - ringR, y: pt.y - ringR)
                    Circle()
                        .fill(Color.red)
                        .frame(width: dotR * 2, height: dotR * 2)
                        .offset(x: pt.x - dotR, y: pt.y - dotR)
                    Path { p in
                        p.move(to: placement.leaderStart)
                        p.addLine(to: placement.leaderEnd)
                    }
                    .stroke(Color.red.opacity(0.9), lineWidth: 1.5)
                    // Label width fills the available bar (no hardcoded cap);
                    // height is natural (driven by content) via .fixedSize.
                    // Vertical center is pinned to the joint when room allows.
                    IssueLabel(issue: issue)
                        .frame(width: placement.labelW, alignment: placement.alignment)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(x: placement.labelX, y: placement.labelY)
                }
                .frame(width: geo.size.width, height: geo.size.height,
                       alignment: .topLeading)
            }
        }
        .allowsHitTesting(false)
    }

    private struct LabelPlacement {
        let labelW: CGFloat
        let labelX: CGFloat
        let labelY: CGFloat
        /// Where the label content aligns inside its frame. Side bars get
        /// `.leading`; top/bottom banners get `.center`.
        let alignment: Alignment
        let leaderStart: CGPoint
        let leaderEnd: CGPoint
    }

    /// Pick a label slot from whichever letterbox has room. Width fills the
    /// available black bar exactly (minus small padding) — no hardcoded
    /// cap, so wider bars get wider labels. Height is dynamic; the leader
    /// line targets the joint's Y level on the label's edge, so we don't
    /// need to know the label's final height up front.
    private func computePlacement(jointPt pt: CGPoint, container: CGSize) -> LabelPlacement {
        let ringR: CGFloat = 16
        let padding: CGFloat = 4
        let minSideBarW: CGFloat = 60
        let minTopBottomBarH: CGFloat = 50
        let leftBar = videoRect.minX
        let rightBar = container.width - videoRect.maxX
        let topBar = videoRect.minY
        let bottomBar = container.height - videoRect.maxY
        let preferRight = pt.x < videoRect.midX

        // Clamp label Y so its likely vertical extent stays in the container.
        // We don't know the exact label height, so reserve a generous chunk.
        func clampedYAround(_ targetY: CGFloat, estHeight: CGFloat = 90) -> CGFloat {
            max(padding, min(container.height - estHeight - padding,
                             targetY - estHeight / 2))
        }

        func rightSide() -> LabelPlacement {
            let w = max(minSideBarW, rightBar - padding * 2)
            let x = videoRect.maxX + padding
            return LabelPlacement(
                labelW: w,
                labelX: x,
                labelY: clampedYAround(pt.y),
                alignment: .leading,
                leaderStart: CGPoint(x: pt.x + ringR, y: pt.y),
                leaderEnd: CGPoint(x: x, y: pt.y)
            )
        }
        func leftSide() -> LabelPlacement {
            let w = max(minSideBarW, leftBar - padding * 2)
            let x = videoRect.minX - w - padding
            return LabelPlacement(
                labelW: w,
                labelX: x,
                labelY: clampedYAround(pt.y),
                alignment: .leading,
                leaderStart: CGPoint(x: pt.x - ringR, y: pt.y),
                leaderEnd: CGPoint(x: x + w, y: pt.y)
            )
        }
        func topBanner() -> LabelPlacement {
            let w = container.width - padding * 2
            let x = padding
            return LabelPlacement(
                labelW: w,
                labelX: x,
                labelY: padding,
                alignment: .center,
                leaderStart: CGPoint(x: pt.x, y: pt.y - ringR),
                leaderEnd: CGPoint(x: pt.x, y: topBar - padding)
            )
        }
        func bottomBanner() -> LabelPlacement {
            let w = container.width - padding * 2
            let x = padding
            // For bottom banner we don't know label height, so place its
            // top at a safe estimate from the bottom of the container.
            let yEst: CGFloat = container.height - 90 - padding
            return LabelPlacement(
                labelW: w,
                labelX: x,
                labelY: yEst,
                alignment: .center,
                leaderStart: CGPoint(x: pt.x, y: pt.y + ringR),
                leaderEnd: CGPoint(x: pt.x, y: videoRect.maxY + padding)
            )
        }
        func insideCorner() -> LabelPlacement {
            // Worst case: no letterbox at all. Drop the label into the top
            // corner OPPOSITE the joint, sized to a quarter of the video.
            let w = videoRect.width * 0.4
            let leftCorner = pt.x >= videoRect.midX
            let x: CGFloat = leftCorner
                ? videoRect.minX + padding
                : videoRect.maxX - w - padding
            // The ball-flight capsule spans most of a narrow video's top, so
            // reserve the strip for BOTH corners, not just the left.
            let y = videoRect.minY + padding + topLeftReserved
            return LabelPlacement(
                labelW: w,
                labelX: x,
                labelY: y,
                alignment: .leading,
                leaderStart: CGPoint(x: pt.x, y: pt.y - ringR),
                leaderEnd: CGPoint(x: x + w / 2, y: y + 40)
            )
        }

        if preferRight && rightBar >= minSideBarW { return rightSide() }
        if !preferRight && leftBar >= minSideBarW { return leftSide() }
        if rightBar >= minSideBarW { return rightSide() }
        if leftBar >= minSideBarW { return leftSide() }
        if topBar >= minTopBottomBarH { return topBanner() }
        if bottomBar >= minTopBottomBarH { return bottomBanner() }
        return insideCorner()
    }

    // MARK: - issue detection

    private func currentIssue(pose: PoseFrame) -> DetectedIssue? {
        // Find the per-event row closest to the current video time, snap to it
        // (otherwise we'd be evaluating metrics at frames we don't have data for).
        guard let pe = nearestPerEvent() else { return nil }
        return IssueRules.detect(
            pe: pe,
            handedness: events.handedness,
            pose: pose
        )
    }

    private func nearestPerEvent() -> PerEventMetrics? {
        var best: PerEventMetrics?
        var bestDist = Int.max
        for pe in perEvent where pe.frame >= 0 {
            let d = abs(pe.frame - currentFrame)
            if d < bestDist { bestDist = d; best = pe }
        }
        return best
    }

    // MARK: - joint projection

    /// Map a pose keypoint to absolute coordinates in the OUTER container,
    /// using the known video rect so the dot lands on the body even when
    /// the overlay frame extends past the video into the side letterbox.
    ///
    /// Two sanity gates before we trust the keypoint:
    /// 1) Per-joint confidence must clear `minJointConfidence`. YOLO will
    ///    happily emit a joint at 0.35 confidence for ambiguous pixels.
    /// 2) The joint must sit within ~1.5× the torso length of the body's
    ///    hip-midpoint. If YOLO latched onto something OTHER than the
    ///    golfer (a poster, a mirror reflection, a person in the
    ///    background), the random joint usually ends up far from the
    ///    detected body's torso — drop it instead of drawing a dot on a
    ///    bookshelf.
    private static let minJointConfidence: Float = 0.55
    private func jointPoint(pose: PoseFrame, joint: Int) -> CGPoint? {
        guard pose.keypoints.indices.contains(joint),
              pose.confidences[joint] > Self.minJointConfidence
        else { return nil }

        // Body-cluster check using the hip + shoulder midpoints.
        let lhip = pose.keypoints[Joint.leftHip]
        let rhip = pose.keypoints[Joint.rightHip]
        let lsh  = pose.keypoints[Joint.leftShoulder]
        let rsh  = pose.keypoints[Joint.rightShoulder]
        let hipsOK = pose.confidences[Joint.leftHip] > 0.4
                  && pose.confidences[Joint.rightHip] > 0.4
        let shouldersOK = pose.confidences[Joint.leftShoulder] > 0.4
                       && pose.confidences[Joint.rightShoulder] > 0.4
        if hipsOK && shouldersOK {
            let hipMidX: Float = (lhip.x + rhip.x) / 2
            let hipMidY: Float = (lhip.y + rhip.y) / 2
            let shMidX: Float = (lsh.x + rsh.x) / 2
            let shMidY: Float = (lsh.y + rsh.y) / 2
            let torso = hypot(Double(shMidX - hipMidX), Double(shMidY - hipMidY))
            let kp = pose.keypoints[joint]
            let dist = hypot(Double(kp.x - hipMidX), Double(kp.y - hipMidY))
            // Joint can't be more than 1.5 torso-lengths away from the hip
            // midpoint. Real body joints fit easily within this; stray
            // keypoints from a misdetected "other person" don't.
            if torso > 0.001, dist > 1.5 * torso {
                return nil
            }
        }

        let kp = pose.keypoints[joint]
        let isoToAniso: CGFloat = pose.isoNormalized
            ? CGFloat(1) / max(0.01, CGFloat(pose.imageAspect)) : 1
        // One-shot diagnostic per overlay session so we can confirm what
        // kp values the LIVE-archived pose actually has, vs UPLOAD's
        // fresh extraction. If kp.x ≈ 0.3 for a body that's clearly at
        // 0.55, the source of truth (stored pose) is wrong — not the
        // renderer.
        if !Self.didDumpJointDiag {
            Self.didDumpJointDiag = true
            let lShoulder = pose.keypoints.indices.contains(Joint.leftShoulder)
                ? pose.keypoints[Joint.leftShoulder] : .zero
            let rShoulder = pose.keypoints.indices.contains(Joint.rightShoulder)
                ? pose.keypoints[Joint.rightShoulder] : .zero
            let lHip = pose.keypoints.indices.contains(Joint.leftHip)
                ? pose.keypoints[Joint.leftHip] : .zero
            let rHip = pose.keypoints.indices.contains(Joint.rightHip)
                ? pose.keypoints[Joint.rightHip] : .zero
            dbg(tag: "issue", String(format:
                "iso=%@ aspect=%.3f videoRect=(%.0f,%.0f,%.0fx%.0f) " +
                "Lsh=(%.3f,%.3f conf=%.2f) Rsh=(%.3f,%.3f conf=%.2f) " +
                "Lhip=(%.3f,%.3f conf=%.2f) Rhip=(%.3f,%.3f conf=%.2f) " +
                "target=%d kp=(%.3f,%.3f conf=%.2f)",
                String(describing: pose.isoNormalized), pose.imageAspect,
                videoRect.minX, videoRect.minY, videoRect.width, videoRect.height,
                lShoulder.x, lShoulder.y, pose.confidences[Joint.leftShoulder],
                rShoulder.x, rShoulder.y, pose.confidences[Joint.rightShoulder],
                lHip.x, lHip.y, pose.confidences[Joint.leftHip],
                rHip.x, rHip.y, pose.confidences[Joint.rightHip],
                joint, kp.x, kp.y, pose.confidences[joint]))
        }
        return CGPoint(
            x: videoRect.minX + CGFloat(kp.x) * isoToAniso * videoRect.width,
            y: videoRect.minY + CGFloat(kp.y) * videoRect.height
        )
    }

    private static var didDumpJointDiag: Bool = false
}

// MARK: - issue label

private struct IssueLabel: View {
    let issue: DetectedIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(issue.metricName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.red)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(issue.valueText)
                .font(.system(size: 16, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(issue.problem)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.75))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.red, lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - issue model

struct DetectedIssue {
    let metricName: String      // "X-factor", "Spine tilt", …
    let valueText: String       // "+12°", "47°", …
    let problem: String         // "too low — turn shoulders more"
    let severity: Double        // 0…1 (higher = worse)
    let joint: Int              // COCO index to anchor the red box on
}

// MARK: - rules

/// One-stop place for "what counts as off" thresholds. Per-metric rules
/// return a `DetectedIssue` only when the value falls outside the OK band,
/// scaled by how far past the OK boundary. Caller picks the worst.
enum IssueRules {
    static func detect(pe: PerEventMetrics,
                       handedness: Handedness,
                       pose: PoseFrame) -> DetectedIssue? {
        let leadElbow  = handedness == .right ? Joint.leftElbow  : Joint.rightElbow
        let trailElbow = handedness == .right ? Joint.rightElbow : Joint.leftElbow
        let leadKnee   = handedness == .right ? Joint.leftKnee   : Joint.rightKnee
        let trailKnee  = handedness == .right ? Joint.rightKnee  : Joint.leftKnee

        var out: [DetectedIssue] = []

        if let v = pe.xFactor {
            // Acceptable absolute X-factor band 20–55°. Below = under-coiled;
            // above = forced shoulder turn / lost hip resistance.
            let a = abs(v)
            let okLo: Double = 20, okHi: Double = 55, hard: Double = 75
            if a < okLo || a > okHi {
                let severity = min(1, max(0, a < okLo ? (okLo - a) / okLo : (a - okHi) / (hard - okHi)))
                out.append(DetectedIssue(
                    metricName: "X-factor",
                    valueText: String(format: "%+.0f°", v),
                    problem: a < okLo
                        ? String(localized: "转肩落后于髋 — 多蓄力")
                        : String(localized: "转过头了 — 髋部失去了抵抗"),
                    severity: severity,
                    joint: Joint.leftShoulder
                ))
            }
        }

        if let v = pe.spineTilt {
            let okLo: Double = 20, okHi: Double = 40, hard: Double = 60
            if v < okLo || v > okHi {
                let severity = min(1, max(0, v < okLo ? (okLo - v) / okLo : (v - okHi) / (hard - okHi)))
                out.append(DetectedIssue(
                    metricName: String(localized: "脊柱前倾"),
                    valueText: String(format: "%.0f°", v),
                    problem: v < okLo
                        ? String(localized: "太直 — 从髋部前倾")
                        : String(localized: "太弓 — 站高一点"),
                    severity: severity,
                    joint: Joint.leftHip
                ))
            }
        }

        if let v = pe.leadElbow {
            // Lead arm: ~160° straight at address & impact. < 140 = chicken wing risk.
            let okLo: Double = 145, hard: Double = 90
            if v < okLo {
                let severity = min(1, (okLo - v) / (okLo - hard))
                out.append(DetectedIssue(
                    metricName: String(localized: "前肘"),
                    valueText: String(format: "%.0f°", v),
                    problem: String(localized: "弯了 — 击球时前臂伸直"),
                    severity: severity,
                    joint: leadElbow
                ))
            }
        }

        if let v = pe.trailElbow {
            // Trail elbow should fold (90–110°) at top; extend through impact (140+).
            // We don't know the event here; flag only extreme straight (≥170 at all
            // times suggests stiff arm) or extreme bend (<60 = collapsed).
            if v < 60 {
                let severity = min(1, (60 - v) / 60)
                out.append(DetectedIssue(
                    metricName: String(localized: "后肘"),
                    valueText: String(format: "%.0f°", v),
                    problem: String(localized: "塌了 — 保持一些支撑结构"),
                    severity: severity,
                    joint: trailElbow
                ))
            }
        }

        if let v = pe.leadKnee {
            // Knee flex: ~155–170° upright with athletic posture.
            let okLo: Double = 145, okHi: Double = 175, hard: Double = 100
            if v < okLo {
                let severity = min(1, (okLo - v) / (okLo - hard))
                out.append(DetectedIssue(
                    metricName: String(localized: "前膝"),
                    valueText: String(format: "%.0f°", v),
                    problem: String(localized: "弯曲过多 — 打穿球时蹬直"),
                    severity: severity,
                    joint: leadKnee
                ))
            } else if v > okHi {
                let severity = min(1, (v - okHi) / 10)
                out.append(DetectedIssue(
                    metricName: String(localized: "前膝"),
                    valueText: String(format: "%.0f°", v),
                    problem: String(localized: "锁死了 — 膝盖保持微屈"),
                    severity: severity,
                    joint: leadKnee
                ))
            }
        }

        if let v = pe.trailKnee {
            let okLo: Double = 140, okHi: Double = 175, hard: Double = 100
            if v < okLo {
                let severity = min(1, (okLo - v) / (okLo - hard))
                out.append(DetectedIssue(
                    metricName: String(localized: "后膝"),
                    valueText: String(format: "%.0f°", v),
                    problem: String(localized: "弯曲过多 — 把重心压到后侧"),
                    severity: severity,
                    joint: trailKnee
                ))
            } else if v > okHi {
                let severity = min(1, (v - okHi) / 10)
                out.append(DetectedIssue(
                    metricName: String(localized: "后膝"),
                    valueText: String(format: "%.0f°", v),
                    problem: String(localized: "蹬直了 — 保持微屈"),
                    severity: severity,
                    joint: trailKnee
                ))
            }
        }

        if let v = pe.shoulderTilt {
            // Shoulder line angle — Address roughly level; large tilt = compensation.
            let absV = abs(v)
            if absV > 25 {
                let severity = min(1, (absV - 25) / 15)
                out.append(DetectedIssue(
                    metricName: String(localized: "双肩"),
                    valueText: String(format: "%+.0f°", v),
                    problem: String(localized: "倾斜 — 后肩往下绕，不要越过去"),
                    severity: severity,
                    joint: Joint.rightShoulder
                ))
            }
        }

        if let v = pe.hipTilt {
            let absV = abs(v)
            if absV > 20 {
                let severity = min(1, (absV - 20) / 15)
                out.append(DetectedIssue(
                    metricName: String(localized: "髋部"),
                    valueText: String(format: "%+.0f°", v),
                    problem: String(localized: "倾斜 — 站位时让髋保持水平"),
                    severity: severity,
                    joint: Joint.rightHip
                ))
            }
        }

        _ = pose   // (reserved for future pose-derived checks, e.g. head movement)
        return out.max(by: { $0.severity < $1.severity })
    }
}
