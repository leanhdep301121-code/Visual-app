import Foundation

struct SwingMetrics: Sendable {
    /// Shoulder turn − hip turn at top, signed degrees. Higher = more torso wind-up.
    var xFactor: Double
    /// Spine vertical tilt at address, degrees (0 = perfectly upright).
    var spineTilt: Double
    /// Backswing frames / downswing frames. Pro reference ~3.0.
    var tempoRatio: Double
    /// Hip line rotation from Address to Top, degrees.
    var hipTurn: Double
    /// Shoulder line rotation from Address to Top, degrees.
    var shoulderTurn: Double
}

/// 8 joint angles sampled at a single event frame. Mirrors the PC
/// dashboard's per-event metric panel.
struct PerEventMetrics: Sendable, Codable, Hashable {
    let event: String     // "Address", "Top", "Impact"…
    let frame: Int        // -1 if not detected
    var shoulderTilt: Double?   // line angle of shoulders
    var hipTilt: Double?        // line angle of hips
    var xFactor: Double?        // shoulderTilt − hipTilt (signed, normalized)
    var spineTilt: Double?      // spine vector vs vertical
    var leadElbow: Double?      // 180° = straight; smaller = more bend
    var trailElbow: Double?
    var leadKnee: Double?
    var trailKnee: Double?
}

/// Trajectory / interval metrics that span multiple frames — the ones a
/// single per-event snapshot can't capture. All positional quantities are
/// normalized by address-frame shoulder width (distance-independent) and use
/// aspect-corrected x (pixel/H units). Direction conventions are baked in so
/// the fault detector reads semantic quantities, not raw signed deltas:
///   - "TowardTarget" positive = moved toward the target (down-the-line)
///   - y is image-space (down = positive), so "rise"/"above" handle the flip
/// Every field is optional — nil when the required events/joints were missing.
struct SwingDynamics: Sendable, Codable, Hashable {
    var headMaxOffset: Double?                  // addr→impact nose max drift / shoulderW
    var headPeakPhase: String?                  // phase where head drift peaked
    var headTowardTargetAtTop: Double?          // @top nose toward-target / W (+=reverse, −=sway)
    var hipTowardTargetAtTop: Double?           // @top hip-center toward-target / W (−=sway away, +=toward)
    var hipRise: Double?                        // addr→impact hip-center rise / W (+ = stood up)
    var hipBumpTowardTarget: Double?            // top→midDs hip toward-target / W (~0 = no fire)
    var hipDriftTowardTargetAtImpact: Double?   // addr→impact hip toward-target / W (large = slide)
    var hipOverFrontFoot: Double?               // @impact (hipMid − leadAnkle) toward-target / W
    var handOutThenIn: Double?                  // OTT proxy: midDs hand bow outward off top→impact line / W
    var spineVariance: Double?                  // max |spineTilt − mean| over addr/top/impact (deg)
    var sideBendTowardTrailAtImpact: Double?    // @impact spine side-lean toward trail (deg, + = good)
    var braceExtension: Double?                 // lead knee angle midDs→impact extension (deg, + = posts up)
    var leadWristAboveShoulderAtTop: Double?    // @top (shoulderY − wristY)/W (small/neg = short backswing)
    var trailElbowAboveShoulderAtTop: Double?   // @top (shoulderY − elbowY)/W (+ = elbow above shoulder = flying)
    var finishWobble: Double?                   // last-frames keypoint jitter / W
}

struct MetricsCalculator {
    func compute(poses rawPoses: [PoseFrame], events: SwingEvents) -> SwingMetrics? {
        let poses = Self.smoothed(rawPoses)
        guard let address = events.frame(for: .address),
              let top = events.frame(for: .top),
              let impact = events.frame(for: .impact),
              address < top, top < impact,
              poses.indices.contains(address),
              poses.indices.contains(top),
              poses.indices.contains(impact)
        else { return nil }

        let shAtAddr = lineAngle(poses[address], a: Joint.leftShoulder, b: Joint.rightShoulder)
        let shAtTop  = lineAngle(poses[top],     a: Joint.leftShoulder, b: Joint.rightShoulder)
        let hipAtAddr = lineAngle(poses[address], a: Joint.leftHip, b: Joint.rightHip)
        let hipAtTop  = lineAngle(poses[top],     a: Joint.leftHip, b: Joint.rightHip)

        let shoulderTurn = signedAngleDelta(from: shAtAddr, to: shAtTop)
        let hipTurn = signedAngleDelta(from: hipAtAddr, to: hipAtTop)
        let xFactor = shoulderTurn - hipTurn

        let spineTilt = spineTiltFromVertical(poses[address])

        let bs = top - address
        let ds = impact - top
        let tempo = ds > 0 ? Double(bs) / Double(ds) : 0

        return SwingMetrics(
            xFactor: xFactor,
            spineTilt: spineTilt,
            tempoRatio: tempo,
            hipTurn: hipTurn,
            shoulderTurn: shoulderTurn
        )
    }

    /// Angle of the line a→b vs horizontal, in degrees.
    ///
    /// CRITICAL: keypoints are anisotropic-normalized (x ÷ width, y ÷ height),
    /// so a raw `atan2(dy, dx)` is distorted by the frame's aspect ratio — on a
    /// 1080×1920 frame a true 10° line reads as ~5.7°. We multiply dx by
    /// `imageAspect` (= W/H) to convert x back into pixel/H units so dx and dy
    /// share units. This matches PoseTCN's feature extractor (which does the
    /// same `kp.x * ax`); previously MetricsCalculator omitted it, so fault
    /// detection ran on a different, distorted angle space than the model.
    private func lineAngle(_ pose: PoseFrame, a: Int, b: Int) -> Double {
        let p1 = pose.keypoints[a]
        let p2 = pose.keypoints[b]
        let aspect = Double(pose.imageAspect)
        return atan2(Double(p2.y - p1.y), Double(p2.x - p1.x) * aspect) * 180 / .pi
    }

    private func signedAngleDelta(from a: Double, to b: Double) -> Double {
        var d = b - a
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    private func spineTiltFromVertical(_ pose: PoseFrame) -> Double {
        let mhx = (pose.keypoints[Joint.leftHip].x + pose.keypoints[Joint.rightHip].x) / 2
        let mhy = (pose.keypoints[Joint.leftHip].y + pose.keypoints[Joint.rightHip].y) / 2
        let msx = (pose.keypoints[Joint.leftShoulder].x + pose.keypoints[Joint.rightShoulder].x) / 2
        let msy = (pose.keypoints[Joint.leftShoulder].y + pose.keypoints[Joint.rightShoulder].y) / 2
        // Same aspect correction as lineAngle — x must be in pixel/H units.
        let dx = Double(msx - mhx) * Double(pose.imageAspect)
        let dy = Double(msy - mhy)
        return atan2(abs(dx), -dy) * 180 / .pi
    }

    /// 8 joint angles per event frame. Skipped (nil) when joint confidence is low.
    func computePerEvent(poses rawPoses: [PoseFrame], events: SwingEvents) -> [PerEventMetrics] {
        let poses = Self.smoothed(rawPoses)
        let isRight = events.handedness == .right
        let leadShoulder = isRight ? Joint.leftShoulder : Joint.rightShoulder
        let leadElbow    = isRight ? Joint.leftElbow    : Joint.rightElbow
        let leadWrist    = isRight ? Joint.leftWrist    : Joint.rightWrist
        let leadHip      = isRight ? Joint.leftHip      : Joint.rightHip
        let leadKnee     = isRight ? Joint.leftKnee     : Joint.rightKnee
        let leadAnkle    = isRight ? Joint.leftAnkle    : Joint.rightAnkle
        let trailShoulder = isRight ? Joint.rightShoulder : Joint.leftShoulder
        let trailElbow    = isRight ? Joint.rightElbow    : Joint.leftElbow
        let trailWrist    = isRight ? Joint.rightWrist    : Joint.leftWrist
        let trailHip      = isRight ? Joint.rightHip      : Joint.leftHip
        let trailKnee     = isRight ? Joint.rightKnee     : Joint.leftKnee
        let trailAnkle    = isRight ? Joint.rightAnkle    : Joint.leftAnkle

        return SwingEvent.allCases.map { ev -> PerEventMetrics in
            let frame = events.frame(for: ev) ?? -1
            guard frame >= 0, frame < poses.count else {
                return PerEventMetrics(event: ev.displayName, frame: frame)
            }
            let p = poses[frame]
            func ok(_ idx: Int) -> Bool { p.confidences[idx] > 0.3 }
            let st = (ok(Joint.leftShoulder) && ok(Joint.rightShoulder))
                ? lineAngle(p, a: Joint.leftShoulder, b: Joint.rightShoulder) : nil
            let ht = (ok(Joint.leftHip) && ok(Joint.rightHip))
                ? lineAngle(p, a: Joint.leftHip, b: Joint.rightHip) : nil
            let xf: Double? = (st != nil && ht != nil) ? signedAngleDelta(from: ht!, to: st!) : nil
            let sp = (ok(Joint.leftHip) && ok(Joint.rightHip)
                      && ok(Joint.leftShoulder) && ok(Joint.rightShoulder))
                ? spineTiltFromVertical(p) : nil
            let le = (ok(leadShoulder) && ok(leadElbow) && ok(leadWrist))
                ? jointAngle(p, leadShoulder, leadElbow, leadWrist) : nil
            let te = (ok(trailShoulder) && ok(trailElbow) && ok(trailWrist))
                ? jointAngle(p, trailShoulder, trailElbow, trailWrist) : nil
            let lk = (ok(leadHip) && ok(leadKnee) && ok(leadAnkle))
                ? jointAngle(p, leadHip, leadKnee, leadAnkle) : nil
            let tk = (ok(trailHip) && ok(trailKnee) && ok(trailAnkle))
                ? jointAngle(p, trailHip, trailKnee, trailAnkle) : nil
            return PerEventMetrics(
                event: ev.displayName, frame: frame,
                shoulderTilt: st, hipTilt: ht, xFactor: xf, spineTilt: sp,
                leadElbow: le, trailElbow: te, leadKnee: lk, trailKnee: tk
            )
        }
    }

    /// Vertex angle ABC at point B (180° = straight). Used for elbow + knee bends.
    /// x components multiplied by `imageAspect` (= W/H) for the same reason as
    /// `lineAngle` — anisotropic-normalized coords distort the vertex angle
    /// otherwise.
    private func jointAngle(_ p: PoseFrame, _ a: Int, _ b: Int, _ c: Int) -> Double {
        let aspect = Double(p.imageAspect)
        let A = p.keypoints[a], B = p.keypoints[b], C = p.keypoints[c]
        let bax = Double(A.x - B.x) * aspect, bay = Double(A.y - B.y)
        let bcx = Double(C.x - B.x) * aspect, bcy = Double(C.y - B.y)
        let dot = bax * bcx + bay * bcy
        let lba = (bax * bax + bay * bay).squareRoot()
        let lbc = (bcx * bcx + bcy * bcy).squareRoot()
        guard lba > 1e-6, lbc > 1e-6 else { return 0 }
        let cosT = max(-1, min(1, dot / (lba * lbc)))
        return Foundation.acos(cosT) * 180 / .pi
    }

    // MARK: - keypoint smoothing

    /// Confidence-weighted centered moving average (window 3) over the pose
    /// sequence. Run before any metric is computed so frame-to-frame keypoint
    /// jitter doesn't leak into angle/position metrics — that jitter was the
    /// main cause of "re-upload the same video, get slightly different numbers".
    ///
    /// Window is deliberately small (3) so it damps noise without smearing the
    /// fast downswing frames. Low-confidence frames get down-weighted, so an
    /// occlusion blip doesn't drag a neighbor off.
    static func smoothed(_ poses: [PoseFrame], window: Int = 3) -> [PoseFrame] {
        guard poses.count > 2, window > 1 else { return poses }
        let half = window / 2
        var out = poses
        for i in poses.indices {
            let lo = max(0, i - half)
            let hi = min(poses.count - 1, i + half)
            var kp = poses[i].keypoints
            for j in 0..<PoseFrame.jointCount {
                var sx: Float = 0, sy: Float = 0, wsum: Float = 0
                for k in lo...hi {
                    let p = poses[k]
                    let w = p.confidences[j]
                    sx += p.keypoints[j].x * w
                    sy += p.keypoints[j].y * w
                    wsum += w
                }
                if wsum > 1e-6 {
                    kp[j] = SIMD2<Float>(sx / wsum, sy / wsum)
                }
            }
            out[i].keypoints = kp
        }
        return out
    }

    // MARK: - dynamics (trajectory / interval metrics)

    /// Compute the multi-frame metrics that per-event snapshots can't.
    /// Operates on smoothed poses. Each quantity guards its own inputs and
    /// returns nil when events/joints are missing, so a partial swing still
    /// yields whatever could be measured.
    func computeDynamics(poses rawPoses: [PoseFrame], events: SwingEvents,
                         viewpoint: Viewpoint = .downTheLine) -> SwingDynamics {
        let poses = Self.smoothed(rawPoses)
        var d = SwingDynamics()
        guard !poses.isEmpty else { return d }

        let isRight = events.handedness == .right
        // Screen-x target direction is MIRRORED between the two camera views: in
        // down-the-line a right-hander's target is screen-left, but face-on the
        // camera faces the player so it's screen-right. Without this flip every
        // toward-target / toward-trail metric (sway, slide, head drift, hip
        // bump, side-bend…) reads with the WRONG sign on face-on clips — which
        // made a clear sway get misclassified as its opposite, reverse pivot.
        let viewSign: Double = (viewpoint == .faceOn) ? -1 : 1
        let toTarget: Double = (isRight ? -1 : 1) * viewSign   // toward-target screen-x sign
        let trailSign: Double = (isRight ? 1 : -1) * viewSign  // toward-trail screen-x sign
        let aspect = Double(poses[0].imageAspect)

        // lead/trail joints
        let leadSh    = isRight ? Joint.leftShoulder : Joint.rightShoulder
        let trailSh   = isRight ? Joint.rightShoulder : Joint.leftShoulder
        let trailElb  = isRight ? Joint.rightElbow : Joint.leftElbow
        let leadWri   = isRight ? Joint.leftWrist : Joint.rightWrist
        let trailWri  = isRight ? Joint.rightWrist : Joint.leftWrist
        let leadHip   = isRight ? Joint.leftHip : Joint.rightHip
        let leadKnee  = isRight ? Joint.leftKnee : Joint.rightKnee
        let leadAnk   = isRight ? Joint.leftAnkle : Joint.rightAnkle

        // accessors (aspect-corrected x, raw y, confidence)
        func X(_ f: Int, _ j: Int) -> Double { Double(poses[f].keypoints[j].x) * aspect }
        func Y(_ f: Int, _ j: Int) -> Double { Double(poses[f].keypoints[j].y) }
        func C(_ f: Int, _ j: Int) -> Float { poses[f].confidences[j] }
        func ok(_ f: Int, _ js: Int...) -> Bool {
            f >= 0 && f < poses.count && js.allSatisfy { C(f, $0) > 0.3 }
        }
        func hipMidX(_ f: Int) -> Double { (X(f, Joint.leftHip) + X(f, Joint.rightHip)) / 2 }
        func hipMidY(_ f: Int) -> Double { (Y(f, Joint.leftHip) + Y(f, Joint.rightHip)) / 2 }
        func shMidX(_ f: Int) -> Double { (X(f, Joint.leftShoulder) + X(f, Joint.rightShoulder)) / 2 }
        func shMidY(_ f: Int) -> Double { (Y(f, Joint.leftShoulder) + Y(f, Joint.rightShoulder)) / 2 }
        func shoulderW(_ f: Int) -> Double? {
            guard ok(f, Joint.leftShoulder, Joint.rightShoulder) else { return nil }
            let dx = X(f, Joint.leftShoulder) - X(f, Joint.rightShoulder)
            let dy = Y(f, Joint.leftShoulder) - Y(f, Joint.rightShoulder)
            let w = (dx * dx + dy * dy).squareRoot()
            return w > 0.02 ? w : nil
        }
        func angle3(_ f: Int, _ a: Int, _ b: Int, _ c: Int) -> Double? {
            guard ok(f, a, b, c) else { return nil }
            let bax = X(f, a) - X(f, b), bay = Y(f, a) - Y(f, b)
            let bcx = X(f, c) - X(f, b), bcy = Y(f, c) - Y(f, b)
            let dot = bax * bcx + bay * bcy
            let lba = (bax * bax + bay * bay).squareRoot()
            let lbc = (bcx * bcx + bcy * bcy).squareRoot()
            guard lba > 1e-6, lbc > 1e-6 else { return nil }
            return acos(max(-1, min(1, dot / (lba * lbc)))) * 180 / .pi
        }
        func spineTilt(_ f: Int) -> Double? {
            guard ok(f, Joint.leftHip, Joint.rightHip, Joint.leftShoulder, Joint.rightShoulder)
            else { return nil }
            let dx = shMidX(f) - hipMidX(f)
            let dy = shMidY(f) - hipMidY(f)
            return atan2(abs(dx), -dy) * 180 / .pi
        }

        let addr = events.frame(for: .address) ?? -1
        let top = events.frame(for: .top) ?? -1
        let midDs = events.frame(for: .midDownswing) ?? -1
        let impact = events.frame(for: .impact) ?? -1

        // baseline shoulder width (address preferred, fall back through swing)
        let baseW = shoulderW(addr) ?? shoulderW(top) ?? shoulderW(impact)

        // --- head stability (addr→impact) ---
        if addr >= 0, impact > addr, ok(addr, Joint.nose), let w = baseW {
            let cx = X(addr, Joint.nose), cy = Y(addr, Joint.nose)
            var maxOff = 0.0, peakFrame = addr
            for f in addr...min(impact, poses.count - 1) where C(f, Joint.nose) > 0.3 {
                let dx = X(f, Joint.nose) - cx, dy = Y(f, Joint.nose) - cy
                let off = (dx * dx + dy * dy).squareRoot() / w
                if off > maxOff { maxOff = off; peakFrame = f }
            }
            d.headMaxOffset = maxOff
            d.headPeakPhase = nearestPhaseName(frame: peakFrame, events: events)
            if ok(top, Joint.nose) {
                d.headTowardTargetAtTop = (X(top, Joint.nose) - cx) * toTarget / w
            }
        }

        // --- hip rise + drifts ---
        if addr >= 0, impact > addr, let w = baseW,
           ok(addr, Joint.leftHip, Joint.rightHip), ok(impact, Joint.leftHip, Joint.rightHip) {
            d.hipRise = (hipMidY(addr) - hipMidY(impact)) / w          // + = lifted up
            d.hipDriftTowardTargetAtImpact = (hipMidX(impact) - hipMidX(addr)) * toTarget / w
            if ok(impact, leadAnk) {
                d.hipOverFrontFoot = (hipMidX(impact) - X(impact, leadAnk)) * toTarget / w
            }
        }
        if top >= 0, midDs > top, let w = baseW,
           ok(top, Joint.leftHip, Joint.rightHip), ok(midDs, Joint.leftHip, Joint.rightHip) {
            d.hipBumpTowardTarget = (hipMidX(midDs) - hipMidX(top)) * toTarget / w
        }
        // Sway = hip center drifts AWAY from the target during the backswing
        // (− toward-target at the top). This is the body-sway signal, separate
        // from the nose-only `headTowardTargetAtTop`.
        if addr >= 0, top > addr, let w = baseW,
           ok(addr, Joint.leftHip, Joint.rightHip), ok(top, Joint.leftHip, Joint.rightHip) {
            d.hipTowardTargetAtTop = (hipMidX(top) - hipMidX(addr)) * toTarget / w
        }

        // --- over-the-top hand path (top→midDs→impact bow) ---
        if top >= 0, impact > top, midDs > top, midDs < impact, let w = baseW,
           ok(top, leadWri, trailWri), ok(midDs, leadWri, trailWri), ok(impact, leadWri, trailWri) {
            func handX(_ f: Int) -> Double { (X(f, leadWri) + X(f, trailWri)) / 2 }
            let r = Double(midDs - top) / Double(impact - top)
            let interp = handX(top) + (handX(impact) - handX(top)) * r
            let dev = handX(midDs) - interp
            d.handOutThenIn = dev * (-toTarget) / w     // + = bowed away from target (outside)
        }

        // --- spine variance (loss of posture) + side bend ---
        let spines = [addr, top, impact].compactMap { $0 >= 0 ? spineTilt($0) : nil }
        if spines.count == 3 {
            let mean = spines.reduce(0, +) / 3
            d.spineVariance = spines.map { abs($0 - mean) }.max()
        }
        if impact >= 0,
           ok(impact, Joint.leftHip, Joint.rightHip, Joint.leftShoulder, Joint.rightShoulder) {
            let dx = shMidX(impact) - hipMidX(impact)
            let dy = shMidY(impact) - hipMidY(impact)
            let signed = atan2(dx, -dy) * 180 / .pi      // +x lean
            d.sideBendTowardTrailAtImpact = signed * trailSign
        }

        // --- brace (lead knee extension midDs→impact) ---
        if let kMid = angle3(midDs, leadHip, leadKnee, leadAnk),
           let kImp = angle3(impact, leadHip, leadKnee, leadAnk) {
            d.braceExtension = kImp - kMid               // + = straightened (posted up)
        }

        // --- top-of-backswing arm/elbow positions ---
        if top >= 0, let w = baseW {
            if ok(top, leadSh, leadWri) {
                d.leadWristAboveShoulderAtTop = (Y(top, leadSh) - Y(top, leadWri)) / w
            }
            if ok(top, trailSh, trailElb) {
                d.trailElbowAboveShoulderAtTop = (Y(top, trailSh) - Y(top, trailElb)) / w
            }
        }

        // --- finish balance (jitter over last frames) ---
        if let w = baseW, poses.count >= 4 {
            let lo = max(0, poses.count - 8)
            var jit = 0.0, cnt = 0
            for f in (lo + 1)..<poses.count
            where ok(f, Joint.leftHip, Joint.rightHip) && ok(f - 1, Joint.leftHip, Joint.rightHip) {
                let dx = hipMidX(f) - hipMidX(f - 1)
                let dy = hipMidY(f) - hipMidY(f - 1)
                jit += (dx * dx + dy * dy).squareRoot() / w
                cnt += 1
            }
            if cnt > 0 { d.finishWobble = jit / Double(cnt) }
        }

        return d
    }

    /// Name of the swing event nearest to a given frame, for "head drifted at
    /// the top" style messaging.
    private func nearestPhaseName(frame: Int, events: SwingEvents) -> String {
        var best = SwingEvent.address
        var bestDiff = Int.max
        for ev in SwingEvent.allCases {
            guard let f = events.frame(for: ev) else { continue }
            let diff = abs(f - frame)
            if diff < bestDiff { bestDiff = diff; best = ev }
        }
        return best.displayName
    }
}
