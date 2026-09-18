import SwiftUI

/// 训练库（设计稿第 10 屏）。把所有挥杆问题对应的训练汇总成一个可浏览的库，
/// 每张卡：图标 + 训练名 + "改善：<问题>" + 观看链接。从"我的"页进入。
struct DrillsView: View {
    /// 所有「问题 → 训练」配对（只保留有训练的问题）。
    private var entries: [(fault: SwingFaultID, drill: Drill)] {
        SwingFaultID.allCases.compactMap { id in
            DrillLibrary.drill(for: id).map { (id, $0) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("跟着练，一个一个改。")
                    .font(.subheadline).foregroundStyle(Theme.inkSecondary)
                    .padding(.bottom, 2)
                ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                    drillCard(fault: e.fault, drill: e.drill)
                }
                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .appBackground()
        .navigationTitle("训练库")
        .navigationBarTitleDisplayMode(.large)
    }

    private func drillCard(fault: SwingFaultID, drill: Drill) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // 图标方块
                RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                    .fill(Theme.surface)
                    .frame(width: 52, height: 52)
                    .overlay(Image(systemName: "play.rectangle.fill").font(.system(size: 22)).foregroundStyle(Theme.accent))
                VStack(alignment: .leading, spacing: 3) {
                    Text(drill.name)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("改善：\(fault.label)")
                        .font(.caption2).foregroundStyle(Theme.accent)
                }
                Spacer()
            }
            Text(drill.howTo)
                .font(.caption).foregroundStyle(Theme.inkSecondary)
                .lineLimit(3)
            if let url = drill.url {
                Link(destination: url) {
                    Label("观看这个训练", systemImage: "play.rectangle.fill")
                        .font(.subheadline.bold()).foregroundStyle(Theme.accentInk)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Theme.accentGrad,
                                    in: RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard(radius: Theme.rMd)
    }
}
