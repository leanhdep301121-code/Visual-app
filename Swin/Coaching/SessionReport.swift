import Foundation

/// LLM-generated 6-field session report. Each field is short (≤30 words) so
/// the whole thing renders fast and reads like a coach's brief.
///
/// Fields are filled progressively while the LLM streams; the UI can render
/// partial state and pop each field in as it lands. `isComplete` indicates
/// the LLM finished and the full object can be persisted.
struct SessionReport: Codable, Sendable {
    /// One-line takeaway. Sets the tone.
    var headline: String

    /// Bare-numbers callout. "30 swings, avg 62, peaked at 89."
    var scoreSummary: String

    /// What the player did well. Reference a specific strength.
    var topStrength: String

    /// What the player should fix, including a concrete drill / cue.
    var topProblemWithFix: String

    /// Session-internal progression — did they get better as they went?
    var sessionProgress: String

    /// Goal for the next session.
    var nextSessionGoal: String

    /// Set to true after the LLM stream finishes.
    var isComplete: Bool

    /// Empty starter for streaming.
    static var empty: SessionReport {
        SessionReport(
            headline: "", scoreSummary: "", topStrength: "",
            topProblemWithFix: "", sessionProgress: "", nextSessionGoal: "",
            isComplete: false
        )
    }

    /// Pretty fallback: when LLM unavailable, generate a deterministic report
    /// from SessionStats so the UI always has something to show.
    static func fallback(from stats: SessionStats) -> SessionReport {
        let s = stats

        let headline: String = {
            if let prev = s.vsPreviousSession {
                let d = prev.avgScoreDelta
                if d > 3 { return String(localized: "明显进步——比上一节高了 \(Int(d.rounded())) 分。") }
                if d < -3 { return String(localized: "状态一般——比上次低了 \(Int((-d).rounded())) 分。") }
                return String(localized: "保持稳定——和上一节差不多水平。")
            }
            if s.avgScore >= 70 { return String(localized: "整体很不错的一节。") }
            if s.avgScore >= 55 { return String(localized: "有好有坏——几杆干净，还有些要练。") }
            return String(localized: "这节有点吃力——我们回到基础上。")
        }()

        let scoreSummary = String(localized: "\(s.swingCount) 杆 · 均分 \(Int(s.avgScore.rounded())) · 区间 \(s.minScore)–\(s.maxScore)。")

        let topStrength: String = {
            if let top = s.strengthRates.first {
                let pct = Int((top.rate * 100).rounded())
                return String(localized: "\(humanStrength(top.id)) 在 \(pct)% 的挥杆里出现。")
            }
            return s.improvementDelta > 5
                ? String(localized: "随着练习，节奏稳下来了。")
                : String(localized: "没有特别突出的——继续积累稳定性。")
        }()

        let topProblemWithFix: String = {
            guard let f = s.faultRates.first else { return String(localized: "今天没有反复出现的问题。") }
            let pct = Int((f.rate * 100).rounded())
            let cue = SwingFaultID(rawValue: f.id)?.fix ?? ""
            return String(localized: "\(humanFault(f.id)) 出现在 \(pct)% 的挥杆里。\(cue)")
        }()

        let sessionProgress: String = {
            if s.improvementDelta > 5 {
                return String(localized: "后程强劲——后半段均分 \(Int(s.secondHalfAvg.rounded()))，前半段 \(Int(s.firstHalfAvg.rounded()))。")
            }
            if s.improvementDelta < -5 {
                return String(localized: "后程下滑——前半段均分 \(Int(s.firstHalfAvg.rounded()))，后半段掉到 \(Int(s.secondHalfAvg.rounded()))。")
            }
            return String(localized: "全程稳定。")
        }()

        let nextSessionGoal: String = {
            guard let f = s.faultRates.first else { return String(localized: "保持节奏，坚持练习。") }
            return String(localized: "下次开头 5 分钟专门练\(humanFault(f.id))。")
        }()

        return SessionReport(
            headline: headline,
            scoreSummary: scoreSummary,
            topStrength: topStrength,
            topProblemWithFix: topProblemWithFix,
            sessionProgress: sessionProgress,
            nextSessionGoal: nextSessionGoal,
            isComplete: true
        )
    }

    private static func humanFault(_ raw: String) -> String {
        SwingFaultID(rawValue: raw)?.label ?? raw.replacingOccurrences(of: "_", with: " ")
    }
    private static func humanStrength(_ raw: String) -> String {
        SwingStrengthID(rawValue: raw)?.label ?? raw.replacingOccurrences(of: "_", with: " ")
    }
}
