import Foundation

/// 把 `CoachingDirective` 用纯代码翻译成一句简短的中文教练话。用于：
///   1. LLM 关闭 / 不可达 / 太慢 时的"立即开口"那句
///   2. LLM 流式调用在预算（2 秒）内没出首字时的兜底
///
/// 句子刻意保持简短（TTS 2 秒内说完），像教练而不是讲课。
struct DirectiveTemplate {
    /// 半确定性——用固定 seed 的选择器，让同一杆序号不总是同一种说法。
    func sentence(for directive: CoachingDirective, swingIndex: Int) -> String {
        let core = coreSentence(for: directive, swingIndex: swingIndex)
        guard !core.isEmpty else { return "" }
        // 接一句简短的"准备好"提示，让用户知道可以开下一杆。
        let cue = pick([
            String(localized: "来。"),
            String(localized: "下一杆。"),
            String(localized: "再来一杆。"),
            String(localized: "准备好就开。"),
            String(localized: "继续。"),
            String(localized: "调整一下再挥。")
        ], seed: swingIndex + 7)
        return "\(core) \(cue)"
    }

    /// 实际反馈内容，不含末尾的准备提示。
    private func coreSentence(for directive: CoachingDirective, swingIndex: Int) -> String {
        switch directive {
        case .skipUnreadable:
            return ""   // 不说话

        case .firstSwingNeutral:
            return pick([
                String(localized: "第一杆，先找找感觉。"),
                String(localized: "这杆有了，再来一次。"),
                String(localized: "第一杆记下了，放松点。"),
                String(localized: "热身一杆完成。"),
            ], seed: swingIndex)

        case .goodOne:
            let praise = pick([
                String(localized: "不错的一杆。"),
                String(localized: "挺扎实。"),
                String(localized: "击球很实。"),
                String(localized: "看着很顺。"),
                String(localized: "保持这个感觉。")
            ], seed: swingIndex)
            return praise

        case .goodStreak(let count, _):
            switch count {
            case 3:    return String(localized: "连着三杆——放松点。")
            case 4:    return String(localized: "连着四杆，什么都别改。")
            case 5...: return String(localized: "连着\(count)杆——你进状态了。")
            default:   return String(localized: "接连命中，保持这个节奏。")
            }

        case .fixOne(let fault, _):
            // 前面带点鼓励，让纠正听起来不像纯批评。
            let opener = pick([
                String(localized: "试试这个——"),
                String(localized: "微调一下："),
                String(localized: "一件事："),
                String(localized: "感受一下："),
                ""
            ], seed: swingIndex &+ fault.hashValue)
            let body = shortenFix(fault.fix)
            return opener.isEmpty ? body : "\(opener) \(body)"

        case .focusLocked(let fault, _):
            // 第一次锁定这个问题——点名 + 给改进。
            let lead = pick([
                String(localized: "我们盯一下\(humanFault(fault))。"),
                String(localized: "又是这个毛病——\(humanFault(fault))。"),
                String(localized: "我看到\(humanFault(fault))一直在。"),
                String(localized: "\(humanFault(fault))老出现。")
            ], seed: swingIndex &+ fault.hashValue)
            return "\(lead) \(shortenFix(fault.fix))"

        case .focusReinforce(let fault, let streak):
            // 之前已经点过名了。语言多变一些，别连着几杆都一个样。
            let fix = shortenFix(fault.fix)
            let humanName = humanFault(fault)
            let variants: [String]
            if streak >= 5 {
                variants = [
                    String(localized: "再坚持一下——\(fix)"),
                    String(localized: "重置，感受\(fix)"),
                    String(localized: "放慢点。\(fix)"),
                    String(localized: "还是这个重点——\(fix)"),
                    String(localized: "\(humanName)再练一次。\(fix)"),
                ]
            } else if streak >= 3 {
                variants = [
                    String(localized: "继续盯着——\(fix)"),
                    String(localized: "接近了。\(fix)"),
                    String(localized: "快了。\(fix)"),
                    String(localized: "相信这个动作——\(fix)"),
                    String(localized: "继续练\(humanName)。\(fix)"),
                ]
            } else {
                variants = [
                    String(localized: "再来——\(fix)"),
                    String(localized: "再一杆——\(fix)"),
                    String(localized: "还是这个——\(fix)"),
                    String(localized: "保持住。\(fix)"),
                    String(localized: "重置。\(fix)"),
                ]
            }
            return pick(variants, seed: swingIndex &+ streak &* 11 &+ fault.hashValue)

        case .focusStuck(let fault):
            // 卡住路径：一句话的改进显然没奏效，换个简单的感觉/训练，并安抚。
            let reassure = pick([
                String(localized: "别急——这个确实有点难。"),
                String(localized: "很正常，这需要多练几次。"),
                String(localized: "我们换个简单点的方式。"),
                String(localized: "跟着我，会练出来的。"),
            ], seed: swingIndex &+ fault.hashValue)
            // 优先用具体训练的做法（一种感觉，而非术语），没有就用问题的改进建议。
            let feel: String = {
                if let d = DrillLibrary.drill(for: fault) {
                    return shortenFix(d.howTo)
                }
                return shortenFix(fault.fix)
            }()
            return String(localized: "\(reassure) 试试这个——\(feel)。")

        case .focusBestEffort(let fault):
            // 从起点改善并到了个人最好水平——认可努力、往下走，而不是再纠正。
            let lines = [
                String(localized: "\(humanFault(fault))这块真有进步——目前到这就很好，再往上叠。"),
                String(localized: "这里进步很大。今天够了——往下走。"),
                String(localized: "你\(humanFault(fault))练了很多——挺扎实。下一个。"),
                String(localized: "比一开始好太多了。先放这儿，继续打。"),
            ]
            return pick(lines, seed: swingIndex &+ fault.hashValue)

        case .focusWaiting(let fault):
            // 焦点锁定中途某一杆问题消失了——给个"对，就是这个方向"，保持鼓励的节奏。
            let lines = [
                String(localized: "好些了——\(humanFault(fault))这杆收了点。"),
                String(localized: "更近了。保持这个感觉。"),
                String(localized: "方向对了。"),
                String(localized: "对——保持这个动作。"),
                String(localized: "干净了点。现在别多想。"),
            ]
            return pick(lines, seed: swingIndex &+ fault.hashValue)

        case .focusImproving(let fault, _):
            // 问题还在，但整体挥杆变好了。给个真诚的"不错"+ 轻提醒要打磨什么。
            let praise = pick([
                String(localized: "不错。"),
                String(localized: "整体好多了。"),
                String(localized: "这是进步。"),
                String(localized: "更近了。"),
                String(localized: "好太多了。")
            ], seed: swingIndex)
            let nudge = pick([
                String(localized: "继续打磨\(humanFault(fault))。"),
                String(localized: "\(humanFault(fault))是最后一块。"),
                String(localized: "盯住\(humanFault(fault))。"),
                String(localized: "\(humanFault(fault))再调准一杆。"),
            ], seed: swingIndex &+ fault.hashValue)
            return "\(praise) \(nudge)"

        case .focusReleased(let fault, _):
            let lines = [
                String(localized: "搞定——\(humanFault(fault))没了。保持住。"),
                String(localized: "就是这样——\(humanFault(fault))清掉了。固定下来。"),
                String(localized: "这杆没有\(humanFault(fault))了。保持这个感觉。"),
                String(localized: "成了——\(humanFault(fault))出去了。保持住。"),
            ]
            return pick(lines, seed: swingIndex &+ fault.hashValue)

        case .neutralProgress:
            return ""
        }
    }

    /// 问题的简短中文说法，适合嵌在句子里（"又是——抡过头了"）。
    private func humanFault(_ fault: SwingFaultID) -> String {
        switch fault {
        case .earlyExtension:       return String(localized: "击球起身")
        case .sway:                 return String(localized: "上杆晃身")
        case .slide:                return String(localized: "顶髋平移")
        case .insufficientXFactor:  return String(localized: "上身转得少")
        case .fastTempo:            return String(localized: "节奏过快")
        case .slowTempo:            return String(localized: "节奏拖沓")
        case .excessiveSpineTilt:   return String(localized: "站位弯腰过多")
        case .chickenWing:          return String(localized: "鸡翅膀")
        case .reversePivot:         return String(localized: "顶点反轴")
        case .shortBackswing:       return String(localized: "上杆过短")
        case .headMovement:         return String(localized: "头部晃动")
        case .lossOfPosture:        return String(localized: "中途姿态走形")
        case .insufficientHipTurn:  return String(localized: "转髋不足")
        case .overTheTop:           return String(localized: "抡过头")
        case .noBrace:              return String(localized: "前腿没支撑")
        case .poorFinish:           return String(localized: "收杆失衡")
        case .flyingElbow:          return String(localized: "顶点飞肘")
        }
    }

    /// 把较长的 .fix 截到第一句、去掉句末句号，便于拼接时通顺。
    /// 兼容中英文句号。
    private func shortenFix(_ fix: String) -> String {
        let firstPart = fix.split(whereSeparator: { $0 == "." || $0 == "。" }).first.map(String.init) ?? fix
        return firstPart.trimmingCharacters(in: .whitespaces)
    }

    private func pick<T>(_ options: [T], seed: Int) -> T {
        let idx = abs(seed) % options.count
        return options[idx]
    }
}
