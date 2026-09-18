import Foundation

/// Mirror of `SwingFaultDetector` — finds positive signals on a swing so the
/// coach (and the session report) has material to compliment the player on.
struct SwingStrengthDetector {
    func detect(report: SwingReport) -> [SwingStrength] {
        var out: [SwingStrength] = []
        if let s = detectStableSpine(report: report)     { out.append(s) }
        if let s = detectGoodTempo(report: report)       { out.append(s) }
        if let s = detectBigXFactor(report: report)      { out.append(s) }
        if let s = detectFullExtension(report: report)   { out.append(s) }
        if let s = detectStableLowerBody(report: report) { out.append(s) }
        if let s = detectAllEventsClean(report: report)  { out.append(s) }
        if let s = detectNoFaults(report: report)        { out.append(s) }
        return out.sorted(by: { $0.confidence > $1.confidence })
    }

    // MARK: - individual detectors

    /// Address vs Impact spine angle change ≤ 4° = no early extension at all.
    private func detectStableSpine(report: SwingReport) -> SwingStrength? {
        guard let addr = perEvent(report, .address)?.spineTilt,
              let imp  = perEvent(report, .impact)?.spineTilt
        else { return nil }
        let delta = abs(addr - imp)
        guard delta <= 4 else { return nil }
        let conf = max(0, min(1, (4 - delta) / 4))   // 4° → 0, 0° → 1
        return SwingStrength(
            id: .stableSpine, confidence: conf, anchorEvent: .impact,
            evidenceValue: delta, evidenceUnit: "° spine change"
        )
    }

    /// Backswing/downswing ratio in [2.5, 3.5] = textbook tempo.
    private func detectGoodTempo(report: SwingReport) -> SwingStrength? {
        guard let t = report.metrics?.tempoRatio, t > 0 else { return nil }
        guard t >= 2.5, t <= 3.5 else { return nil }
        let dist = abs(t - 3.0)
        let conf = max(0, min(1, 1 - dist / 0.5))    // 3.0 → 1, 2.5 or 3.5 → 0
        return SwingStrength(
            id: .goodTempo, confidence: conf, anchorEvent: .top,
            evidenceValue: t, evidenceUnit: ":1 backswing/downswing"
        )
    }

    /// |X-factor| at Top ≥ 40° = strong torso load (pro-grade).
    private func detectBigXFactor(report: SwingReport) -> SwingStrength? {
        guard let xf = perEvent(report, .top)?.xFactor else { return nil }
        let absXF = abs(xf)
        guard absXF >= 40 else { return nil }
        let conf = min(1, (absXF - 40) / 20)         // 40° → 0, 60° → 1
        return SwingStrength(
            id: .bigXFactor, confidence: conf, anchorEvent: .top,
            evidenceValue: absXF, evidenceUnit: "° X-factor"
        )
    }

    /// Mid-follow-through lead elbow ≥ 165° = full extension through the ball.
    private func detectFullExtension(report: SwingReport) -> SwingStrength? {
        guard let le = perEvent(report, .midFollowThrough)?.leadElbow else { return nil }
        guard le >= 165 else { return nil }
        let conf = min(1, (le - 165) / 15)           // 165° → 0, 180° → 1
        return SwingStrength(
            id: .fullExtension, confidence: conf, anchorEvent: .midFollowThrough,
            evidenceValue: le, evidenceUnit: "° lead elbow"
        )
    }

    /// Hip mid-x drift Address → Impact, normalized by shoulder width, ≤ 12%.
    /// Pivot, not slide.
    private func detectStableLowerBody(report: SwingReport) -> SwingStrength? {
        guard let address = report.events.frame(for: .address),
              let impact  = report.events.frame(for: .impact),
              report.poseFrames.indices.contains(address),
              report.poseFrames.indices.contains(impact)
        else { return nil }
        let addrPose = report.poseFrames[address]
        let impPose  = report.poseFrames[impact]
        guard let addrHipX = hipMidX(addrPose),
              let impHipX  = hipMidX(impPose),
              let shW = shoulderWidth(addrPose)
        else { return nil }
        let drift = abs(Double(impHipX - addrHipX) / Double(shW))
        guard drift <= 0.12 else { return nil }
        let conf = max(0, min(1, 1 - drift / 0.12))
        return SwingStrength(
            id: .stableLowerBody, confidence: conf, anchorEvent: .impact,
            evidenceValue: drift * 100, evidenceUnit: "% of shoulder width"
        )
    }

    /// All 8 events detected AND average joint conf ≥ 0.6 across the swing.
    private func detectAllEventsClean(report: SwingReport) -> SwingStrength? {
        let detected = report.events.frames.allSatisfy { $0 >= 0 }
        guard detected else { return nil }
        let keyJoints = [Joint.leftShoulder, Joint.rightShoulder,
                         Joint.leftHip, Joint.rightHip,
                         Joint.leftWrist, Joint.rightWrist]
        var sum: Double = 0; var n = 0
        for pose in report.poseFrames {
            for j in keyJoints { sum += Double(pose.confidences[j]); n += 1 }
        }
        let avgConf = n > 0 ? sum / Double(n) : 0
        guard avgConf >= 0.6 else { return nil }
        let conf = min(1, (avgConf - 0.6) / 0.3)
        return SwingStrength(
            id: .allEventsClean, confidence: conf, anchorEvent: nil,
            evidenceValue: avgConf * 100, evidenceUnit: "% avg joint confidence"
        )
    }

    /// No SwingFaults fired = "no flags" strength. The score formula already
    /// rewards this, but it's useful to surface as an explicit strength too.
    private func detectNoFaults(report: SwingReport) -> SwingStrength? {
        let faults = SwingFaultDetector().detect(report: report)
        guard faults.isEmpty else { return nil }
        return SwingStrength(
            id: .noFaults, confidence: 1.0, anchorEvent: nil,
            evidenceValue: nil, evidenceUnit: nil
        )
    }

    // MARK: - helpers

    private func perEvent(_ report: SwingReport, _ event: SwingEvent) -> PerEventMetrics? {
        return report.perEvent.first(where: { $0.event == event.displayName })
    }

    private func hipMidX(_ p: PoseFrame) -> Float? {
        guard p.confidences[Joint.leftHip] > 0.3,
              p.confidences[Joint.rightHip] > 0.3 else { return nil }
        return (p.keypoints[Joint.leftHip].x + p.keypoints[Joint.rightHip].x) / 2
    }

    private func shoulderWidth(_ p: PoseFrame) -> Float? {
        guard p.confidences[Joint.leftShoulder] > 0.3,
              p.confidences[Joint.rightShoulder] > 0.3 else { return nil }
        let dx = p.keypoints[Joint.leftShoulder].x - p.keypoints[Joint.rightShoulder].x
        let dy = p.keypoints[Joint.leftShoulder].y - p.keypoints[Joint.rightShoulder].y
        let w = sqrt(dx * dx + dy * dy)
        return w > 0.02 ? w : nil
    }
}
