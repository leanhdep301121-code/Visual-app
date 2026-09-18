import SwiftUI

/// 品牌色 —— 已对齐权威设计稿（深色科技风）的青绿强调色。
///
/// 历史上 Brand 是粉色 logo 色，全 app 大量直接引用。设计稿改为青绿后，
/// 与其逐个改 60+ 处引用，不如在源头把这几个值重定义为青绿，所有引用
/// 一次性翻新（和 Theme 的向后兼容别名同理）。新代码请直接用 `Theme.accent`。
///   - `Brand.primary`     → 青绿主强调色 #00E0B8（= Theme.accent）
///   - `Brand.primaryLight` → 青绿（高亮/标签用）
///   - `Brand.primaryDeep` → 青蓝 #00B4D8（= Theme.accent2，渐变深端）
///   - `Brand.gradient`    → 青绿渐变（= Theme.accentGrad）
enum Brand {
    static let primary      = Theme.accent              // #00E0B8 青绿
    static let primaryLight = Theme.accent              // 高亮也用青绿（深底上够亮）
    static let primaryDeep  = Theme.accent2             // #00B4D8 青蓝

    /// 青绿渐变。主 CTA / hero 卡片 / 进度条用。
    static let gradient = Theme.accentGrad

    /// 卡片/chip 的淡背景着色。
    static let surfaceTint = Theme.accent.opacity(0.12)
}
