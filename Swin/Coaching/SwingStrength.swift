import Foundation

/// A detected "this is what the player did WELL" on this swing — the
/// counterpart to `SwingFault`. Pure code detection, same input → same output.
///
/// Used by the session report so the LLM has explicit material to compliment
/// the player on, not just a list of problems.
enum SwingStrengthID: String, Codable, Sendable, CaseIterable {
    case stableSpine          = "stable_spine"          // address vs impact spine change ≤ 4°
    case goodTempo            = "good_tempo"            // 2.5..3.5 backswing/downswing
    case bigXFactor           = "big_x_factor"          // top |X-factor| ≥ 40°
    case fullExtension        = "full_extension"        // mid-fl lead elbow ≥ 165°
    case stableLowerBody      = "stable_lower_body"     // small hip drift over swing
    case allEventsClean       = "all_events_clean"      // 8/8 events detected, high confidence
    case noFaults             = "no_faults"             // SwingFaultDetector returned []

    var label: String {
        switch self {
        case .stableSpine:     return String(localized: "脊柱角度稳定")
        case .goodTempo:       return String(localized: "节奏流畅")
        case .bigXFactor:      return String(localized: "上身蓄力充分")
        case .fullExtension:   return String(localized: "前臂充分伸展")
        case .stableLowerBody: return String(localized: "下盘稳定")
        case .allEventsClean:  return String(localized: "挥杆弧线干净")
        case .noFaults:        return String(localized: "没有发现问题")
        }
    }
}

/// A strength that actually fired for a given swing, with the supporting number.
struct SwingStrength: Codable, Sendable, Hashable {
    let id: SwingStrengthID
    /// 0…1; how strong is the signal. 1.0 = textbook example.
    let confidence: Double
    let anchorEvent: SwingEvent?
    let evidenceValue: Double?
    let evidenceUnit: String?
}
