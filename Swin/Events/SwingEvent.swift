import Foundation

enum Handedness: Sendable { case right, left }

enum SwingEvent: Int, CaseIterable, Codable, Hashable, Sendable {
    case address = 0
    case toeUp
    case midBackswing
    case top
    case midDownswing
    case impact
    case midFollowThrough
    case finish

    var displayName: String {
        switch self {
        case .address: return String(localized: "站位")
        case .toeUp: return String(localized: "起杆")
        case .midBackswing: return String(localized: "上杆中段")
        case .top: return String(localized: "顶点")
        case .midDownswing: return String(localized: "下杆中段")
        case .impact: return String(localized: "击球")
        case .midFollowThrough: return String(localized: "送杆中段")
        case .finish: return String(localized: "收杆")
        }
    }
}

struct SwingEvents: Sendable {
    /// Frame index per event in canonical order. -1 = not detected.
    var frames: [Int]
    var handedness: Handedness

    func frame(for event: SwingEvent) -> Int? {
        let idx = frames[event.rawValue]
        return idx >= 0 ? idx : nil
    }

    static let undetected = SwingEvents(
        frames: Array(repeating: -1, count: SwingEvent.allCases.count),
        handedness: .right
    )
}

/// COCO 17 joint indices used throughout event/metric code.
enum Joint {
    static let nose = 0
    static let leftEye = 1, rightEye = 2
    static let leftEar = 3, rightEar = 4
    static let leftShoulder = 5, rightShoulder = 6
    static let leftElbow = 7, rightElbow = 8
    static let leftWrist = 9, rightWrist = 10
    static let leftHip = 11, rightHip = 12
    static let leftKnee = 13, rightKnee = 14
    static let leftAnkle = 15, rightAnkle = 16
}
