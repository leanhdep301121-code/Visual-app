import Foundation

/// Soft qualitative tier — replaces user-facing 0-100 numeric score. A swing
/// is always one of these labels; the underlying numeric sub-scores live on
/// `SwingScore` for internal use (sorting, baseline drift, telemetry).
enum SwingTier: String, Codable, Sendable, Hashable, CaseIterable {
    case clean       // no significant faults, clean mechanics
    case solid       // 1 minor fault, otherwise good
    case mixed       // 2+ faults or 1 significant fault — actionable feedback
    case off         // major faults, swing needs serious work
    case unclear     // detection too poor to evaluate (bad framing, occlusion)

    /// User-facing English label.
    var label: String {
        switch self {
        case .clean:   return String(localized: "干净")
        case .solid:   return String(localized: "扎实")
        case .mixed:   return String(localized: "还需打磨")
        case .off:     return String(localized: "偏差大")
        case .unclear: return String(localized: "难以判读")
        }
    }
}

/// Aggregate evaluation of one swing. All pure code: no LLM, no network,
/// no learned model. Stable input → stable output.
///
/// The user-facing surface is `tier` + faults; the numeric `total` and
/// sub-scores are kept for internal sorting / telemetry but should NOT
/// be displayed as primary feedback (per product direction — numbers feel
/// like grades).
struct SwingScore: Codable, Sendable, Hashable {
    /// Soft qualitative tier. Use this for UI labels.
    let tier: SwingTier
    /// Internal 0-100 weighted total. Higher = better. Hidden from primary UI.
    let total: Int
    let detectionQuality: Double   // 0-1, are the inputs trustworthy?
    let mechanicalScore: Double    // 0-1, faults present?
    let tempoScore: Double         // 0-1, is tempo in a healthy range?
    let consistencyScore: Double   // 0-1, how close to user's baseline?
    let faults: [SwingFault]       // sorted strongest-first
    let primaryFault: SwingFaultID?

    /// One-line "why this tier" for UI/LLM context. Built deterministically.
    var summaryShort: String {
        switch tier {
        case .clean:   return String(localized: "干净利落的一杆")
        case .solid:
            if let f = primaryFault { return String(localized: "扎实 — 注意\(f.label)") }
            return String(localized: "扎实的一杆")
        case .mixed:
            if let f = primaryFault { return String(localized: "练一练\(f.label)") }
            return String(localized: "还行 — 有几处要收拾")
        case .off:
            if let f = primaryFault { return String(localized: "先改\(f.label)") }
            return String(localized: "偏差较大 — 需要练")
        case .unclear: return String(localized: "这一杆没看清楚")
        }
    }
}

/// Optional rolling baseline of the user's own recent swings, for the
/// consistency sub-score. Pass nil during a cold start (first few swings).
struct UserBaseline: Sendable {
    let avgXFactor: Double
    let avgTempo: Double
    let avgSpineTilt: Double
    let nSwings: Int
}

struct SwingScorer {
    private let faultDetector = SwingFaultDetector()

    /// Weights for the four sub-scores. Sum to 1.0. Mechanical is the bulk
    /// because that's where most actionable signal lives.
    private let weightDetection: Double  = 0.20
    private let weightMechanical: Double = 0.50
    private let weightTempo: Double      = 0.20
    private let weightConsistency: Double = 0.10

    func score(report: SwingReport, baseline: UserBaseline? = nil) -> SwingScore {
        let detection  = detectionQuality(report)
        let faults     = faultDetector.detect(report: report)
        let mechanical = mechanicalScore(faults: faults)
        let tempo      = tempoScore(report: report)
        let consistency = consistencyScore(report: report, baseline: baseline)

        let weightedRaw =
            weightDetection   * detection +
            weightMechanical  * mechanical +
            weightTempo       * tempo +
            weightConsistency * consistency

        // Hard floor only kicks in when detection is truly garbage (no joints,
        // events totally missing). Back-view / wide-angle DTL footage can still
        // yield useful PoseTCN signal even with detectionQuality ~0.3, so the
        // cap only fires below 0.2 and only down to 50 (mid-range) rather than
        // 30 (which read as "bad swing" to users when really it was just framing).
        let total: Int
        if detection < 0.2 {
            total = min(50, Int(weightedRaw * 100))
        } else {
            total = max(0, min(100, Int((weightedRaw * 100).rounded())))
        }

        let tier = derivePolicyTier(
            detection: detection,
            faults: faults,
            mechanical: mechanical
        )

        return SwingScore(
            tier: tier,
            total: total,
            detectionQuality: detection,
            mechanicalScore: mechanical,
            tempoScore: tempo,
            consistencyScore: consistency,
            faults: faults,
            primaryFault: faults.first?.id
        )
    }

    /// Map (detection, faults, mechanical) → soft tier. Tunable thresholds
    /// kept here so UI is decoupled from numeric internals.
    private func derivePolicyTier(detection: Double,
                                  faults: [SwingFault],
                                  mechanical: Double) -> SwingTier {
        if detection < 0.2 { return .unclear }
        let significantFaults = faults.filter { $0.severity >= 0.5 }
        let minorFaults      = faults.filter { $0.severity > 0 && $0.severity < 0.5 }
        if significantFaults.isEmpty && minorFaults.isEmpty { return .clean }
        if significantFaults.isEmpty && minorFaults.count <= 1 { return .solid }
        if significantFaults.count >= 2 { return .off }
        if significantFaults.count == 1, let top = significantFaults.first, top.severity >= 0.75 {
            return .off
        }
        return .mixed
    }

    // MARK: - sub-scores

    /// 1) Detection quality: did pose + events come through cleanly?
    ///   - Are all 8 events detected (non -1)?
    ///   - Average joint confidence across the swing window
    ///   - Frame count sane (> 30, < 240)
    private func detectionQuality(_ report: SwingReport) -> Double {
        let n = report.events.frames.filter { $0 >= 0 }.count
        let eventCoverage = Double(n) / 8.0      // 0…1

        let frameCount = report.poseFrames.count
        let frameCountScore: Double
        if frameCount < 20 || frameCount > 300 { frameCountScore = 0.0 }
        else if frameCount < 30 || frameCount > 240 { frameCountScore = 0.5 }
        else { frameCountScore = 1.0 }

        // Average conf on the 6 key joints over the whole clip.
        let keyJoints = [Joint.leftShoulder, Joint.rightShoulder,
                         Joint.leftHip, Joint.rightHip,
                         Joint.leftWrist, Joint.rightWrist]
        var confSum: Double = 0
        var confCount = 0
        for pose in report.poseFrames {
            for j in keyJoints {
                confSum += Double(pose.confidences[j])
                confCount += 1
            }
        }
        let avgConf = confCount > 0 ? confSum / Double(confCount) : 0
        let confScore = max(0, min(1, (avgConf - 0.2) / 0.5))   // 0.2 → 0, 0.7 → 1

        return 0.5 * eventCoverage + 0.25 * frameCountScore + 0.25 * confScore
    }

    /// 2) Mechanical score: 1.0 if no faults; subtract each fault's severity,
    ///    capped at 0. Multiple faults stack.
    private func mechanicalScore(faults: [SwingFault]) -> Double {
        // Slight non-linearity: one severity-0.5 fault drops score to ~0.55;
        // two stack to ~0.20. Diminishing returns so 5 tiny faults don't zero out.
        let totalPenalty = faults.reduce(0) { $0 + $1.severity * 0.9 }
        return max(0, 1.0 - totalPenalty)
    }

    /// 3) Tempo score: distance from the ideal 3.0 backswing/downswing ratio.
    private func tempoScore(report: SwingReport) -> Double {
        guard let t = report.metrics?.tempoRatio, t > 0 else { return 0.5 }
        let ideal = 3.0
        let dist = abs(t - ideal)
        return max(0, 1.0 - dist / 2.0)   // 0 from ideal → 1.0, 2 away → 0
    }

    /// 4) Consistency: closeness to user's rolling average. Cold-start → 1.0
    ///    so first few swings aren't unfairly penalized.
    private func consistencyScore(report: SwingReport, baseline: UserBaseline?) -> Double {
        guard let b = baseline, b.nSwings >= 5,
              let m = report.metrics else { return 1.0 }
        func closeness(_ value: Double, baseline: Double, tolerance: Double) -> Double {
            let dist = abs(value - baseline)
            return max(0, 1 - dist / tolerance)
        }
        let xfClose    = closeness(m.xFactor, baseline: b.avgXFactor, tolerance: 20)
        let tempoClose = closeness(m.tempoRatio, baseline: b.avgTempo, tolerance: 1.5)
        let spineClose = closeness(m.spineTilt, baseline: b.avgSpineTilt, tolerance: 15)
        return (xfClose + tempoClose + spineClose) / 3.0
    }
}
