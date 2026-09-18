import Foundation

/// A single detectable swing problem. Each fault carries:
///   - an ID for matching across swings (streak counting)
///   - a `severity` 0…1 (how bad in this swing)
///   - a short user-facing label and a longer fix instruction the LLM can lean on
///
/// Detection lives in `SwingFaultDetector.detect(report:)`. Adding a new fault
/// means: add a case here, add a detector method, append to the master list.
enum SwingFaultID: String, Codable, Sendable, CaseIterable {
    case earlyExtension       = "early_extension"
    case sway                 = "sway"
    case slide                = "slide"
    case insufficientXFactor  = "insufficient_xfactor"
    case fastTempo            = "fast_tempo"
    case slowTempo            = "slow_tempo"
    case excessiveSpineTilt   = "excessive_spine_tilt"
    case chickenWing          = "chicken_wing"
    // -- newly added (expanded coaching surface) --
    case reversePivot         = "reverse_pivot"           // spine leans toward target at top
    case shortBackswing       = "short_backswing"         // lead arm not horizontal at top
    case headMovement         = "head_movement"           // head drifts addr→impact
    case lossOfPosture        = "loss_of_posture"         // spine angle varies through swing
    case insufficientHipTurn  = "insufficient_hip_turn"   // hips < 35° at top
    // -- v0.2 additions (combination-judged) --
    case overTheTop           = "over_the_top"            // hand path out-then-in early downswing
    case noBrace              = "no_brace"                // lead leg doesn't post up at impact
    case poorFinish           = "poor_finish"             // unbalanced / incomplete finish
    case flyingElbow          = "flying_elbow"            // trail elbow lifts above shoulder at top

    /// Plain-English short label, e.g. for chip UI / brief callouts.
    var label: String {
        switch self {
        case .earlyExtension:       return String(localized: "起身（顶髋）")
        case .sway:                 return String(localized: "上杆右移（晃身）")
        case .slide:                return String(localized: "击球时顶髋平移")
        case .insufficientXFactor:  return String(localized: "顶点转肩不足（X-factor低）")
        case .fastTempo:            return String(localized: "节奏过快")
        case .slowTempo:            return String(localized: "节奏过慢")
        case .excessiveSpineTilt:   return String(localized: "起始时弯腰过多")
        case .chickenWing:          return String(localized: "送杆时鸡翅膀（前臂弯）")
        case .reversePivot:         return String(localized: "顶点反向重心（反轴）")
        case .shortBackswing:       return String(localized: "上杆过短")
        case .headMovement:         return String(localized: "头部晃动")
        case .lossOfPosture:        return String(localized: "姿态走形")
        case .insufficientHipTurn:  return String(localized: "转髋不足")
        case .overTheTop:           return String(localized: "下杆抡过头（out-to-in）")
        case .noBrace:              return String(localized: "前腿未支撑发力")
        case .poorFinish:           return String(localized: "收杆失衡")
        case .flyingElbow:          return String(localized: "顶点飞肘")
        }
    }

    /// Plain-English, jargon-free label for the USER-facing UI. The `label`
    /// above keeps coaching terms ("X-factor", "over the top") for internal /
    /// LLM use; this one describes the MOVEMENT a beginner can picture. Used by
    /// the Issues list and the cause-effect graph.
    var plainLabel: String {
        switch self {
        case .earlyExtension:       return String(localized: "击球瞬间身子站了起来")
        case .sway:                 return String(localized: "上杆时整个身子往右滑出去了")
        case .slide:                return String(localized: "髋部往目标方向平移过去了")
        case .insufficientXFactor:  return String(localized: "顶点时上半身没转够")
        case .fastTempo:            return String(localized: "挥得稍微快了点")
        case .slowTempo:            return String(localized: "挥得稍微慢了点")
        case .excessiveSpineTilt:   return String(localized: "站位时弯腰弯得太多")
        case .chickenWing:          return String(localized: "击球后前臂往上弯了起来")
        case .reversePivot:         return String(localized: "顶点时身子反而往目标侧倾")
        case .shortBackswing:       return String(localized: "上杆幅度太短")
        case .headMovement:         return String(localized: "挥杆过程中头一直在动")
        case .lossOfPosture:        return String(localized: "挥到一半姿态变了")
        case .insufficientHipTurn:  return String(localized: "上杆时髋部没转够")
        case .overTheTop:           return String(localized: "从顶点直接往球扑出去")
        case .noBrace:              return String(localized: "击球时前腿没撑住")
        case .poorFinish:           return String(localized: "收杆时没站稳")
        case .flyingElbow:          return String(localized: "顶点时后肘抬离了身体")
        }
    }

    /// One-sentence English fix instruction. Used as LLM seed / TTS fallback.
    var fix: String {
        switch self {
        case .earlyExtension:
            return String(localized: "击球时屁股往后顶住——想象后面有面墙，你正贴着墙坐下去。")
        case .sway:
            return String(localized: "上杆时绕着右髋转，而不是整个身子往右滑出去。")
        case .slide:
            return String(localized: "击球时别把髋往目标方向平推——要把它转开。")
        case .insufficientXFactor:
            return String(localized: "顶点时把肩充分转过去，同时让髋部少转一些。")
        case .fastTempo:
            return String(localized: "把起杆放慢——上杆与下杆争取做到 3 比 1。")
        case .slowTempo:
            return String(localized: "下杆时加快一点——果断打穿球。")
        case .excessiveSpineTilt:
            return String(localized: "站位时站得高一点——从髋部前倾，不是弓背。")
        case .chickenWing:
            return String(localized: "打穿球时，前臂充分朝目标方向伸直。")
        case .reversePivot:
            return String(localized: "顶点时重心应该在右脚（后侧）——感觉往后脚里压，而不是往目标侧倒。")
        case .shortBackswing:
            return String(localized: "把转身做完整——顶点时让前臂转到与地面平行（或更高）。")
        case .headMovement:
            return String(localized: "在球上选一个点，击球全程让头稳在它上方——少上下点、少左右移。")
        case .lossOfPosture:
            return String(localized: "保持脊柱角度不变——从站位到击球同一个姿态，中途别站起来也别弓背。")
        case .insufficientHipTurn:
            return String(localized: "上杆时把髋转进去——顶点时前膝应指向球或球的后方。")
        case .overTheTop:
            return String(localized: "下杆从地面发起——让髋先动、球杆顺势落到身后，而不是把杆往球的方向甩出去。")
        case .noBrace:
            return String(localized: "击球时前腿撑起来——感觉它蹬直、顶住地面把力量释放出去。")
        case .poorFinish:
            return String(localized: "把收杆定住——充分转到前脚侧，在那儿稳住一拍。")
        case .flyingElbow:
            return String(localized: "顶点时后肘往下、收在肋骨前方——别让它抬离身体。")
        }
    }

    /// The metric chip the UI should highlight when surfacing this fault.
    /// Maps to `PerEventMetrics` keys.
    var anchorMetric: String {
        switch self {
        case .earlyExtension, .excessiveSpineTilt, .lossOfPosture: return "spine_tilt"
        case .sway, .slide, .reversePivot:                         return "hip_tilt"
        case .insufficientXFactor:                                 return "x_factor"
        case .fastTempo, .slowTempo:                               return "tempo"
        case .chickenWing, .shortBackswing:                        return "lead_elbow"
        case .headMovement:                                        return "head_pos"
        case .insufficientHipTurn:                                 return "hip_turn"
        case .overTheTop:                                          return "hand_path"
        case .noBrace:                                             return "lead_knee"
        case .poorFinish:                                          return "balance"
        case .flyingElbow:                                         return "trail_elbow"
        }
    }

    /// The camera angle this fault reads most reliably from, given 2D limits.
    /// Rotation / head / weight-shift faults need the body facing the lens
    /// (face-on); path / posture / plane faults need the down-the-line view.
    /// Tempo is angle-agnostic (nil). When the clip's viewpoint ≠ this, the UI
    /// flags the read as "better seen from …". First-pass mapping per the 5/30
    /// viewpoint-visibility doc — for the expert to confirm.
    var bestViewpoint: Viewpoint? {
        switch self {
        case .insufficientXFactor, .insufficientHipTurn, .headMovement,
             .sway, .slide, .reversePivot, .noBrace, .poorFinish:
            return .faceOn
        case .overTheTop, .earlyExtension, .lossOfPosture, .excessiveSpineTilt,
             .shortBackswing, .flyingElbow, .chickenWing:
            return .downTheLine
        case .fastTempo, .slowTempo:
            return nil
        }
    }

    /// A viewpoint from which this fault is geometrically INVISIBLE in 2D — any
    /// value computed from that angle is a projection artifact, so the fault is
    /// hidden entirely (not reported) for clips shot from here. Stronger than
    /// `bestViewpoint` (which only means "less reliable, still shown"). nil =
    /// readable enough from both angles to keep with a soft hint.
    var hiddenViewpoint: Viewpoint? {
        switch self {
        // Rotation magnitude (shoulder/hip turn ⇒ X-factor) lives in the plane
        // perpendicular to a down-the-line camera — a side view simply can't
        // measure how far the body turned.
        case .insufficientXFactor, .insufficientHipTurn:
            return .downTheLine
        // Club/hand path in-and-out (over-the-top) is DEPTH from face-on — the
        // camera looks straight down the line of travel and sees none of it.
        case .overTheTop:
            return .faceOn
        default:
            return nil
        }
    }

    /// Causal layer for root-vs-symptom ranking. Setup/backswing faults are
    /// generally upstream (root cause), follow-through faults downstream
    /// (symptom). FaultRanker weights the combined score by this so a root
    /// cause outranks the symptoms it produces. Engineering first-pass — the
    /// exact causal graph is for the expert to confirm.
    var layer: FaultLayer {
        switch self {
        case .earlyExtension, .overTheTop, .sway, .reversePivot, .excessiveSpineTilt:
            return .root
        case .insufficientXFactor, .insufficientHipTurn, .shortBackswing,
             .flyingElbow, .lossOfPosture, .headMovement, .fastTempo, .slowTempo:
            return .mid
        case .chickenWing, .slide, .noBrace, .poorFinish:
            return .symptom
        }
    }
}

/// Causal layer for root-vs-symptom ranking.
enum FaultLayer: Sendable {
    case root, mid, symptom
    var weight: Double {
        switch self {
        case .root:    return 1.0
        case .mid:     return 0.7
        case .symptom: return 0.4
        }
    }
}

/// A fault that fired for a particular swing, with severity + anchor frame.
struct SwingFault: Codable, Sendable, Hashable {
    let id: SwingFaultID
    /// 0…1; how bad in this swing. ≥0.5 = clearly visible.
    let severity: Double
    /// The event frame this fault is most visible at, e.g. Impact for early
    /// extension. Lets UI scrub to that frame on tap.
    let anchorEvent: SwingEvent?
    /// The numeric value behind the call, for context. e.g. spine tilt delta.
    let evidenceValue: Double?
    let evidenceUnit: String?
    /// 0-1 confidence this call is real. Composed from margin-past-threshold ×
    /// supporting-evidence count. The ranker drops low-confidence faults
    /// ("don't report what you're not sure of"). Optional so old archived
    /// SwingScores (which lacked it) still decode.
    var confidence: Double? = nil
    /// How far past the trigger threshold this swing is, normalized 0-1.
    /// Feeds confidence and lets the UI show "just over the line" vs "way off".
    var margin: Double? = nil
    /// In-scope, significant root causes that likely produced THIS (symptom)
    /// fault — the causal chain. nil for root causes themselves or unrelated
    /// faults. Lets both the UI and the LLM show "A is causing B" instead of
    /// listing flat. Optional so old archived SwingScores still decode.
    var causedBy: [SwingFaultID]? = nil
}

// MARK: - Drill library (curriculum)

/// One practice drill for a fault. `url` points at a PUBLIC teaching video,
/// opened in the browser / YouTube (NOT embedded or downloaded).
struct Drill: Sendable {
    let name: String
    let howTo: String
    let url: URL?
}

/// Fault → recommended drill. ⚑ ENGINEERING FIRST-PASS: drills + public YouTube
/// links matched by topic only (video quality NOT vetted, no rights cleared for
/// embedding — links open externally). Expert to curate the drills and, before
/// release, swap to owned/licensed content. Wired into the curriculum: a fault
/// that keeps recurring (faultTally) surfaces its drill.
enum DrillLibrary {
    static func drill(for id: SwingFaultID) -> Drill? {
        func u(_ s: String) -> URL? { URL(string: s) }
        switch id {
        case .earlyExtension:
            return Drill(name: String(localized: "靠墙挥杆"),
                         howTo: String(localized: "起始时屁股轻贴墙（或椅子）。击球全程让髋部保持后顶贴住它，而不是往球的方向顶出去。"),
                         url: u("https://www.youtube.com/watch?v=mEwbW4qTYR4"))
        case .lossOfPosture:
            return Drill(name: String(localized: "保持脊柱角度"),
                         howTo: String(localized: "从站位到击球，感觉胸口一直对着球往下，别让上半身提前抬起。"),
                         url: u("https://www.youtube.com/watch?v=1l_T-n64X4k"))
        case .excessiveSpineTilt:
            return Drill(name: String(localized: "运动姿态站位"),
                         howTo: String(localized: "站高一点，从髋部前倾（不是弯腰），膝盖微屈——别在站位时弓背。"),
                         url: u("https://www.youtube.com/watch?v=5DKOUdIOAaM"))
        case .headMovement:
            return Drill(name: String(localized: "稳头练习"),
                         howTo: String(localized: "在球上选一个点，让头稳在它上方；可以让朋友拿杆轻轻贴在你头边作参照，再挥杆。"),
                         url: u("https://www.youtube.com/watch?v=FzOssUgSkgw"))
        case .sway:
            return Drill(name: String(localized: "原地转身"),
                         howTo: String(localized: "绕着右髋转，而不是往右滑出去——感觉右髋往后转，不是平移出去。"),
                         url: u("https://www.youtube.com/watch?v=L66SapEuCww"))
        case .slide:
            return Drill(name: String(localized: "要转不要滑"),
                         howTo: String(localized: "下杆时把髋转开，而不是越过球往目标方向平推。"),
                         url: u("https://www.youtube.com/watch?v=wvbinJsRVxs"))
        case .insufficientXFactor:
            return Drill(name: String(localized: "肩髋分离"),
                         howTo: String(localized: "顶点时，感觉肩继续转、髋部抵住不动——两者之间的这股拉伸就是你的力量。"),
                         url: u("https://www.youtube.com/watch?v=rBhSxSyVZtY"))
        case .insufficientHipTurn:
            return Drill(name: String(localized: "充分蓄力转身"),
                         howTo: String(localized: "上杆时把髋和肩充分转进去，让前肩转到球的后方。"),
                         url: u("https://www.youtube.com/watch?v=XWpt5jDmiv0"))
        case .shortBackswing:
            return Drill(name: String(localized: "把转身做完整"),
                         howTo: String(localized: "顶点时让前臂转到与地面平行（或更高）——把上杆做完，别中途收住。"),
                         url: u("https://www.youtube.com/watch?v=ESiMmG5JDd0"))
        case .overTheTop:
            return Drill(name: String(localized: "杆头套障碍练习"),
                         howTo: String(localized: "在球的外侧放一个杆头套；下杆从地面发起，让球杆从内侧落下、绕过它。"),
                         url: u("https://www.youtube.com/watch?v=NxvyxTmPya4"))
        case .chickenWing:
            return Drill(name: String(localized: "打穿球后伸展"),
                         howTo: String(localized: "感觉前臂保持伸长并转动（不是折起来）过击球点——双臂朝目标伸出去。"),
                         url: u("https://www.youtube.com/watch?v=hkWoRYYOJVE"))
        case .reversePivot:
            return Drill(name: String(localized: "正确蓄力压重心"),
                         howTo: String(localized: "上杆时把重心压到右脚（后侧），而不是在顶点往目标方向倒。"),
                         url: u("https://www.youtube.com/watch?v=560nvmnoyDk"))
        case .noBrace:
            return Drill(name: String(localized: "前腿蹬直支撑"),
                         howTo: String(localized: "击球时蹬地、把前腿蹬直，撑住地面、把速度释放出来。"),
                         url: u("https://www.youtube.com/watch?v=fzI4nmtMtDM"))
        case .flyingElbow:
            return Drill(name: String(localized: "后肘夹书练习"),
                         howTo: String(localized: "顶点时让后肘往下、收在肋骨前方——别让它抬离身体。"),
                         url: u("https://www.youtube.com/watch?v=rto6LbPQDe0"))
        case .poorFinish:
            return Drill(name: String(localized: "平衡收杆"),
                         howTo: String(localized: "挥到一个完整、平衡的收杆姿势，重心在前脚上，定住一拍。"),
                         url: u("https://www.youtube.com/watch?v=N26R3212vX8"))
        case .fastTempo:
            return Drill(name: String(localized: "别赶节奏"),
                         howTo: String(localized: "把转换放平顺——感觉顶点处稍微停顿一下再下杆；争取上杆与下杆 3 比 1 的节奏。"),
                         url: u("https://www.youtube.com/watch?v=HIBcDxGHjqk"))
        case .slowTempo:
            return Drill(name: String(localized: "找到你的节奏"),
                         howTo: String(localized: "用稳定、有运动感的节奏果断打穿球——别在击球时减速。"),
                         url: u("https://www.youtube.com/watch?v=dx-H4ntMcGs"))
        }
    }
}
