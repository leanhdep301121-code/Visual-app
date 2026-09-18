import Foundation

/// Local rule-based feedback used as offline fallback when the cloud LLM is unreachable.
/// Starter set covering the most common faults; expand from PC `examples_library.py`
/// when that lands.
struct RuleTemplate: Sendable {
    let id: String
    let name: String
    let metric: String
    let predicate: @Sendable (SwingMetrics) -> Bool
    let cause: String
    let fix: String
    let drill: String?
}

final class RuleTemplateService: @unchecked Sendable {
    let templates: [RuleTemplate] = [
        RuleTemplate(
            id: "low_xfactor",
            name: String(localized: "X-factor 不足"),
            metric: "x_factor",
            predicate: { abs($0.xFactor) < 25 },
            cause: String(localized: "Top 时肩髋分离不到 25°，意味着躯干没有储能。理想 X-factor 是 35-45°。"),
            fix: String(localized: "Top 时主动让左肩转到下巴下方，髋部保持稳定不跟着转过去。"),
            drill: String(localized: "镜前慢动作：先转髋 45°，再独立把肩转到 90°，感受拉伸感。")
        ),
        RuleTemplate(
            id: "fast_tempo",
            name: String(localized: "节奏过快"),
            metric: "tempo_ratio",
            predicate: { $0.tempoRatio > 0 && $0.tempoRatio < 2.5 },
            cause: String(localized: "上下杆比例小于 2.5:1，下杆抢节奏。理想是 BS:DS = 3:1。"),
            fix: String(localized: "Top 后停 0.2 秒再下杆，重心转移先于手臂发力。"),
            drill: String(localized: "节拍器 4 拍：tic(start)-tic-tic(top)-toc(impact) 均匀。")
        ),
        RuleTemplate(
            id: "slow_tempo",
            name: String(localized: "节奏拖沓"),
            metric: "tempo_ratio",
            predicate: { $0.tempoRatio > 4.0 },
            cause: String(localized: "上下杆比例大于 4:1，下杆失去爆发力，球速会偏低。"),
            fix: String(localized: "Top 后立刻启动下杆，让髋先于手臂触发。"),
            drill: nil
        ),
        RuleTemplate(
            id: "spine_tilt_collapse",
            name: String(localized: "脊柱前倾不足"),
            metric: "spine_tilt",
            predicate: { $0.spineTilt < 15 },
            cause: String(localized: "Address 时脊柱几乎竖直，挥杆面会过于平直，容易薄/顶球。"),
            fix: String(localized: "Address 时髋向后坐 + 上身前倾 25-30°，下巴对着球。"),
            drill: String(localized: "杆贴胸口练习：把球杆横抵胸口，做半挥让杆始终贴胸。")
        ),
        RuleTemplate(
            id: "spine_tilt_excess",
            name: String(localized: "脊柱前倾过度"),
            metric: "spine_tilt",
            predicate: { $0.spineTilt > 45 },
            cause: String(localized: "Address 前倾大于 45°，容易在下杆时主动起身（early extension）。"),
            fix: String(localized: "降低前倾到 25-30°，膝盖微弯而不是上身过度前压。"),
            drill: nil
        ),
        RuleTemplate(
            id: "low_hip_turn",
            name: String(localized: "髋部转动不足"),
            metric: "hip_turn",
            predicate: { abs($0.hipTurn) < 25 },
            cause: String(localized: "Top 时髋只转了不到 25°,下半身没有参与挥杆,主要靠上身手臂发力。"),
            fix: String(localized: "Address 时右脚内侧主动蹬地,带动右髋向后转。"),
            drill: String(localized: "椅子练习:坐在椅子边沿做无杆挥杆,感受髋部主动旋转。")
        ),
        RuleTemplate(
            id: "low_shoulder_turn",
            name: String(localized: "肩转动不足"),
            metric: "shoulder_turn",
            predicate: { abs($0.shoulderTurn) < 70 },
            cause: String(localized: "Top 时肩转动不到 70°,挥杆弧线短,失去距离。"),
            fix: String(localized: "Top 时左肩要转到下巴下方,左臂尽量伸直。"),
            drill: String(localized: "对墙站立,保持背部贴墙做转肩,确认转到 90°。")
        ),
        RuleTemplate(
            id: "extreme_xfactor",
            name: String(localized: "X-factor 过大"),
            metric: "x_factor",
            predicate: { abs($0.xFactor) > 60 },
            cause: String(localized: "Top 时肩髋分离超过 60°,身体超出柔韧度,容易引发下背部代偿。"),
            fix: String(localized: "把上下分离控制在 35-50°,先稳住下半身再做肩部转动。"),
            drill: String(localized: "做无杆挥杆,先髋转 45°再单独转肩到位,感受拉伸但不发力。")
        ),
        RuleTemplate(
            id: "shoulder_turn_excess",
            name: String(localized: "肩部转过头"),
            metric: "shoulder_turn",
            predicate: { abs($0.shoulderTurn) > 110 },
            cause: String(localized: "Top 时肩转动超过 110°,Top 位失控,下杆容易失去节奏。"),
            fix: String(localized: "Top 不追求最大转幅,左肩到下巴下方即可停。"),
            drill: String(localized: "镜前练习设定 Top 上限位,左肩到位即停,不再追加。")
        ),
        RuleTemplate(
            id: "hip_over_turn",
            name: String(localized: "髋部过度转动"),
            metric: "hip_turn",
            predicate: { abs($0.hipTurn) > 60 },
            cause: String(localized: "Top 时髋转超过 60°,下半身储能流失,身体没有阻力。"),
            fix: String(localized: "保持右膝弯曲不蹬直,髋只转 35-45° 就够。"),
            drill: String(localized: "脚内侧夹球做挥杆,确认髋部不过度松开。")
        ),
    ]

    func feedback(report: SwingReport) -> FeedbackResponse {
        guard let metrics = report.metrics else {
            return FeedbackResponse(
                summary: String(localized: "动作识别不完整,请尝试重新录一次。"),
                eventTips: [],
                source: .template
            )
        }
        let matched = templates.filter { $0.predicate(metrics) }
        let tips = matched.map { t in
            FeedbackTip(
                event: nil, userFrame: nil, metric: t.metric,
                tip: t.name, cause: t.cause, fix: t.fix, drill: t.drill
            )
        }
        let summary: String
        if tips.isEmpty {
            summary = String(localized: "动作整体在合理范围内,继续保持节奏。")
        } else {
            let topTwo = tips.prefix(2).map(\.fix).joined(separator: " ")
            summary = String(localized: "检测到 \(tips.count) 个可改进点。\(topTwo)")
        }
        return FeedbackResponse(summary: summary, eventTips: tips, source: .template)
    }
}
