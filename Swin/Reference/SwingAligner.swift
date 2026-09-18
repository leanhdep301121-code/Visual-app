import CoreMedia
import Foundation

/// Aligns a Pro reference swing onto the user's clip for the comparison overlay.
///
/// **Model (v3 — event-synced timeline, frozen spatial transform).**
/// Two concerns, kept orthogonal:
///
/// 1. **Time (which Pro frame to show)** — driven by the user's CURRENT frame,
///    warped through the 8 event anchors (`proFrame(forUserFrame:…)`). So the
///    Pro hits Top when the user hits Top, Impact when the user hits Impact,
///    and when the user slow-mos / scrubs, the Pro follows on the same
///    timeline. This also makes Pro source FPS / slow-motion irrelevant: we
///    warp by event-relative fraction, not absolute time. The user sees the
///    rhythm *difference* as numbers (per-phase durations in the tempo ribbon),
///    not as the overlay drifting out of sync.
///
/// 2. **Space (where to draw it)** — a SINGLE frozen similarity transform
///    (uniform scale + translation, optional horizontal mirror) derived once
///    from the user's Address pose. Re-deriving anchor/scale every frame from
///    the live noisy pose was the source of the overlay JITTER; freezing it
///    means the only on-screen motion is the Pro's own smooth motion.
///
/// Mirror is decided from pose GEOMETRY (which way each body faces), not the
/// `handedness` metadata — that field is unreliable / mislabeled in some
/// bundled references.
enum SwingAligner {

    /// Frozen registration: corresponding Address landmark midpoints (ankle,
    /// knee, hip, shoulder) for Pro and user. The overlay computes a
    /// least-squares similarity (scale + rotation + translation) mapping the
    /// Pro set onto the user set, so the WHOLE body fits as well as possible —
    /// no single pair is pinned exactly, which spreads the unavoidable
    /// proportion/posture difference across the figure instead of dumping it
    /// into the legs (what a 2-point feet+shoulders pin did). The similarity
    /// also preserves the Pro's native pixel aspect (no squish from differing
    /// video aspect ratios). All points are normalized [0,1] in their own
    /// video's image space; `proPts[i]` corresponds to `userPts[i]`.
    struct Registration: Sendable {
        let proPts: [SIMD2<Float>]
        let userPts: [SIMD2<Float>]
        /// Flip horizontally so the Pro faces the same way as the user.
        let mirror: Bool
    }

    /// Map the user's current frame to the Pro frame to display, warping
    /// piecewise-linearly between the 8 event anchors. Keeps the two swings
    /// synced on the timeline regardless of differing tempo / source FPS.
    static func proFrame(forUserFrame t: Int, userEvents: [Int], proEvents: [Int]) -> Int {
        guard userEvents.count == 8, proEvents.count == 8 else { return 0 }
        // Before the first valid event → clamp to its Pro frame.
        if let firstU = userEvents.first(where: { $0 >= 0 }),
           t <= firstU,
           let firstIdx = userEvents.firstIndex(where: { $0 >= 0 }) {
            return max(0, proEvents[firstIdx])
        }
        for i in 0..<7 {
            let uStart = userEvents[i]
            let uEnd = userEvents[i + 1]
            if uStart < 0 || uEnd < 0 { continue }
            if t < uStart { continue }
            if t < uEnd {
                let span = max(1, uEnd - uStart)
                let frac = Double(t - uStart) / Double(span)
                let pStart = proEvents[i]
                let pEnd = proEvents[i + 1]
                if pStart < 0 || pEnd < 0 { return max(0, pStart) }
                return pStart + Int((Double(pEnd - pStart) * frac).rounded())
            }
        }
        // Past the last detected event → hold the last Pro frame.
        return proEvents.last(where: { $0 >= 0 }) ?? 0
    }

    /// Build the frozen registration from the user's swing report and the Pro
    /// reference. Collects corresponding Address landmark midpoints (ankle,
    /// knee, hip, shoulder) for both bodies — the user's median-filtered over a
    /// ±3-frame window so a single noisy pose can't bias the fit. The overlay
    /// least-squares-fits a similarity over these, fitting the whole body
    /// rather than pinning any one joint. Mirror is decided by comparing each
    /// body's Address facing (shoulder-mid vs hip-mid lean).
    static func register(report: SwingReport, pro: ProReference) -> Registration? {
        guard pro.events.count == 8, !pro.frames.isEmpty,
              let addr = report.events.frame(for: .address),
              report.poseFrames.indices.contains(addr)
        else { return nil }

        let lo = max(0, addr - 3)
        let hi = min(report.poseFrames.count - 1, addr + 3)
        let proAddressFrame = max(0, min(pro.frames.count - 1, pro.events[0]))
        let pa = pro.frames[proAddressFrame]

        // Joint pairs whose midpoint we register on. Feet + hip + shoulder —
        // the body's main stations; knee is omitted (noisier, and it pulled
        // the fit away from the landmarks the user actually compares).
        let segments: [(String, Int, Int)] = [
            ("ankle",    Joint.leftAnkle,    Joint.rightAnkle),
            ("hip",      Joint.leftHip,      Joint.rightHip),
            ("shoulder", Joint.leftShoulder, Joint.rightShoulder),
        ]

        var proPts = [SIMD2<Float>](), userPts = [SIMD2<Float>]()
        var uAnk: SIMD2<Float>?, uSh: SIMD2<Float>?, uHip: SIMD2<Float>?
        for (name, a, b) in segments {
            // Pro midpoint at Address — needs both sides confident.
            guard pa.conf[a] > 0.3, pa.conf[b] > 0.3 else { continue }
            let pPt = proMid(pa, a, b)
            // User midpoint: median over the window across confident frames.
            var xs = [Float](), ys = [Float]()
            for i in lo...hi {
                let p = report.poseFrames[i]
                guard p.confidences[a] > 0.3, p.confidences[b] > 0.3 else { continue }
                let m = midpoint(p.keypoints, a, b)
                xs.append(m.x); ys.append(m.y)
            }
            guard !xs.isEmpty else { continue }
            let uPt = SIMD2<Float>(median(xs), median(ys))
            proPts.append(pPt); userPts.append(uPt)
            if name == "ankle" { uAnk = uPt }
            if name == "shoulder" { uSh = uPt }
            if name == "hip" { uHip = uPt }
        }

        // Need at least the spine endpoints for a stable fit.
        guard proPts.count >= 2, let uAnk, let uSh, let uHip,
              abs(uAnk.y - uSh.y) > 0.05 else { return nil }

        // Mirror the Pro iff the user and the Pro have OPPOSITE handedness.
        // Both bundled Pros are already viewpoint-matched (face-on Pro for a
        // face-on clip, DTL Pro for DTL), so within a viewpoint the only thing
        // that flips which way the body faces on screen is handedness:
        //   right-handed user + right-handed Pro → identical facing → no mirror
        //   left-handed  user + right-handed Pro → opposite facing  → mirror
        // We deliberately do NOT infer facing from pose geometry (the old
        // shoulder-mid − hip-mid offset): at Address that offset is a tiny,
        // noisy quantity whose SIGN flips with pose jitter, so the Pro overlay
        // would face a different way swing-to-swing within ONE session. Driving
        // it off the session handedness makes it deterministic + stable.
        let userRight = report.events.handedness == .right
        let proRight = pro.handedness.lowercased().hasPrefix("r")
        let mirror = userRight != proRight
        _ = (uSh, uHip)   // still needed above for the spine-stability guard

        return Registration(proPts: proPts, userPts: userPts, mirror: mirror)
    }

    // MARK: - helpers

    private static func midpoint(_ kp: [SIMD2<Float>], _ a: Int, _ b: Int) -> SIMD2<Float> {
        SIMD2<Float>((kp[a].x + kp[b].x) / 2, (kp[a].y + kp[b].y) / 2)
    }

    private static func proMid(_ f: ProReference.Frame, _ a: Int, _ b: Int) -> SIMD2<Float> {
        SIMD2<Float>((f.x[a] + f.x[b]) / 2, (f.y[a] + f.y[b]) / 2)
    }

    private static func median(_ xs: [Float]) -> Float {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }
}
