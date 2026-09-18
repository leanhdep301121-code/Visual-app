import SwiftUI

/// One swing phase (the span between two consecutive events) with the user's
/// and the Pro's duration for it.
struct TempoPhase: Identifiable, Sendable {
    let id: Int
    let name: String
    let color: Color
    let userSec: Double
    let proSec: Double
}

/// Side-by-side tempo comparison: two ribbons (You vs Pro) segmented by swing
/// phase, plus the backswing:downswing ratio headline.
///
/// This is the home for the phase-length signal that the overlay deliberately
/// does NOT warp away. Two normalization modes (the user asked for both):
///   • **Proportion** — both ribbons equal width; shows where you spend
///     relatively more/less of the swing. Best for "your transition is rushed".
///   • **Seconds** — true real durations to a shared seconds scale; shows the
///     absolute tempo difference (a fast swing's ribbon is literally shorter).
struct TempoComparisonView: View {
    let phases: [TempoPhase]

    enum Mode: String, CaseIterable { case proportion = "比例", seconds = "秒数" }
    @State private var mode: Mode = .proportion

    private var userTotal: Double { phases.reduce(0) { $0 + $1.userSec } }
    private var proTotal: Double { phases.reduce(0) { $0 + $1.proSec } }

    /// Backswing = Address→Top (phases 0..2), Downswing = Top→Impact (3..4).
    private var userBS: Double { phases.prefix(3).reduce(0) { $0 + $1.userSec } }
    private var userDS: Double { phases[safe: 3..<5].reduce(0) { $0 + $1.userSec } }
    private var proBS: Double { phases.prefix(3).reduce(0) { $0 + $1.proSec } }
    private var proDS: Double { phases[safe: 3..<5].reduce(0) { $0 + $1.proSec } }

    private var userRatio: Double? { userDS > 0.001 ? userBS / userDS : nil }
    private var proRatio: Double? { proDS > 0.001 ? proBS / proDS : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)

            // Shared seconds scale so both ribbons are comparable in Seconds
            // mode; in Proportion mode each fills its own row.
            let maxTotal = max(userTotal, proTotal, 0.001)
            ribbonRow(label: String(localized: "你"), phases: phases, isUser: true, maxTotal: maxTotal)
            ribbonRow(label: String(localized: "职业"), phases: phases, isUser: false, maxTotal: maxTotal)
            legend
        }
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("节奏（上杆 : 下杆）")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ratioChip(String(localized: "你"), userRatio, tint: Brand.primary)
                    ratioChip(String(localized: "职业"), proRatio, tint: .secondary)
                }
            }
            Spacer()
            if let v = verdict { Text(v).font(.caption.bold()).foregroundStyle(verdictTint) }
        }
    }

    private func ratioChip(_ label: String, _ ratio: Double?, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(ratio.map { String(format: "%.1f : 1", $0) } ?? "—")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(tint)
        }
    }

    /// Qualitative read on the user's transition relative to a tour-typical 3:1.
    private var verdict: String? {
        guard let r = userRatio else { return nil }
        if r < 2.4 { return String(localized: "转换偏急") }
        if r > 3.6 { return String(localized: "下杆偏拖") }
        return String(localized: "节奏接近职业")
    }
    private var verdictTint: Color {
        guard let r = userRatio else { return .secondary }
        return (r >= 2.4 && r <= 3.6) ? .green : .orange
    }

    private func ribbonRow(label: String, phases: [TempoPhase], isUser: Bool, maxTotal: Double) -> some View {
        let total = isUser ? userTotal : proTotal
        return HStack(spacing: 8) {
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            GeometryReader { geo in
                let fullW = geo.size.width
                // Proportion: fill the whole row. Seconds: scale to the longer
                // of the two totals so the shorter swing reads as shorter.
                let rowW = mode == .proportion ? fullW : fullW * CGFloat(total / maxTotal)
                let denom = mode == .proportion ? max(total, 0.001) : max(total, 0.001)
                HStack(spacing: 1) {
                    ForEach(phases) { ph in
                        let sec = isUser ? ph.userSec : ph.proSec
                        let w = rowW * CGFloat(sec / denom)
                        ph.color
                            .frame(width: max(0, w))
                            .opacity(isUser ? 0.95 : 0.55)
                    }
                }
                .frame(width: rowW, height: 18, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 18)
            Text(String(format: "%.2fs", total))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                  alignment: .leading, spacing: 4) {
            ForEach(phases) { ph in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(ph.color).frame(width: 10, height: 10)
                    Text(ph.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

private extension Array where Element == TempoPhase {
    /// Slice over a half-open index range, clamped to bounds.
    subscript(safe range: Range<Int>) -> [TempoPhase] {
        let lo = Swift.max(0, range.lowerBound)
        let hi = Swift.min(count, range.upperBound)
        return lo < hi ? Array(self[lo..<hi]) : []
    }
}
