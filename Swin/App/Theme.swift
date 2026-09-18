import SwiftUI

/// GoSwin 设计系统 —— 「液态玻璃 / Liquid Glass（Apple 风）」，风格画廊 No.14，
/// 对标 Apple / Instagram 级精致度。浅色：柔和的 蓝→藕粉→薄荷绿 渐变 + 柔焦色球
/// 做出液态纵深 + 白色磨砂玻璃面板（系统 Material 真模糊，叠镜面高光 + 受光渐变边 +
/// 双层柔和投影）+ iOS 蓝强调。
///
/// token（来自画廊 .s14）：
///   背景  150° #BFD8EE→#E8D9E4@55%→#CFE5D6，上叠柔焦色球
///   面板  白磨砂(.regularMaterial) + 顶部镜面高光 + 上亮下暗发丝边 + 蓝灰柔投影
///   文字  #1D1D1F（近黑）· 次 #54565C · 弱 #8A8A8F
///   强调  #007AFF（iOS 蓝）· 强调上的字=白 · 渐变端 #0062E0
///   语义  warn #FF3B30 · good #34C759 · gold #FF9500
///   圆角  大 22 · 中 16 · 小 10（玻璃容器常用 20/34）
///   字体  大数字/标题 SF Rounded（Theme.display）· 正文 SF
enum Theme {
    // 背景渐变三段色 + 柔焦色球用色
    static let bgTop    = Color(.sRGB, red: 0.749, green: 0.847, blue: 0.933) // #BFD8EE 蓝
    static let bgMid    = Color(.sRGB, red: 0.910, green: 0.851, blue: 0.894) // #E8D9E4 藕粉
    static let bgBot    = Color(.sRGB, red: 0.812, green: 0.898, blue: 0.839) // #CFE5D6 薄荷
    static let orbBlue  = Color(.sRGB, red: 0.482, green: 0.682, blue: 0.953) // 蓝球
    static let orbLilac = Color(.sRGB, red: 0.812, green: 0.706, blue: 0.918) // 丁香紫球
    static let orbMint  = Color(.sRGB, red: 0.612, green: 0.886, blue: 0.776) // 薄荷球
    static let orbPeach = Color(.sRGB, red: 0.984, green: 0.812, blue: 0.745) // 蜜桃球
    static let bg       = bgTop
    static let bg2      = bgBot

    // 面板 fallback 色（玻璃主要用 Material）
    static let surface  = Color.white.opacity(0.55)
    static let surface2 = Color.white.opacity(0.62)
    static let line     = Color.white.opacity(0.65)
    static let videoBg  = Color(.sRGB, red: 0.024, green: 0.031, blue: 0.047) // #06080C 视频区深底

    // 文字
    static let text     = Color(.sRGB, red: 0.114, green: 0.114, blue: 0.122) // #1D1D1F
    static let textDim  = Color(.sRGB, red: 0.329, green: 0.337, blue: 0.361) // #54565C
    static let textMute = Color(.sRGB, red: 0.541, green: 0.541, blue: 0.561) // #8A8A8F

    // 强调 + 语义
    static let accent    = Color(.sRGB, red: 0.0,   green: 0.478, blue: 1.0)   // #007AFF iOS 蓝
    static let accent2   = Color(.sRGB, red: 0.0,   green: 0.384, blue: 0.878) // #0062E0 渐变深端
    static let accentInk = Color.white
    static let warn      = Color(.sRGB, red: 1.0,   green: 0.231, blue: 0.188) // #FF3B30
    static let good      = Color(.sRGB, red: 0.204, green: 0.780, blue: 0.349) // #34C759
    static let gold      = Color(.sRGB, red: 1.0,   green: 0.584, blue: 0.0)   // #FF9500

    // 蓝灰柔投影色（来自 No.14 阴影 rgba(60,80,110,…)）
    static let shadowSoft = Color(.sRGB, red: 0.235, green: 0.314, blue: 0.431)

    // 圆角
    static let rLg: CGFloat = 22
    static let rMd: CGFloat = 16
    static let rSm: CGFloat = 10

    // 渐变
    /// 强调渐变 —— 上浅下深的玻璃蓝，给 CTA 一点光泽。
    static let accentGrad = LinearGradient(
        colors: [Color(.sRGB, red: 0.231, green: 0.580, blue: 1.0), accent, accent2],
        startPoint: .top, endPoint: .bottom)
    /// 全屏基底渐变（柔焦色球在 AppBackground 里叠加）。
    static let appBg = LinearGradient(
        stops: [.init(color: bgTop, location: 0.0),
                .init(color: bgMid, location: 0.55),
                .init(color: bgBot, location: 1.0)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let accentGlow = accent.opacity(0.30)

    /// 大数字 / 展示标题字体 —— SF Rounded（对标 Apple Fitness 的高级数字感）。
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // ---- 向后兼容别名 ----
    static var stage: LinearGradient { appBg }
    static var ink: Color { text }
    static var inkSecondary: Color { textDim }
    static let cardRadius = rMd
}

/// 液态玻璃全屏背景：基底渐变 + 四颗柔焦色球（蓝/丁香/薄荷/蜜桃）做出
/// 有机的颜色纵深，磨砂面板会把这些颜色淡淡折射出来。
struct AppBackground: View {
    var body: some View {
        ZStack {
            Theme.appBg
            orb(Theme.orbBlue,  size: 360, x: -150, y: -260, blur: 70, op: 0.55)
            orb(Theme.orbLilac, size: 300, x:  170, y: -160, blur: 80, op: 0.50)
            orb(Theme.orbMint,  size: 380, x:  -90, y:  420, blur: 90, op: 0.45)
            orb(Theme.orbPeach, size: 240, x:  180, y:  300, blur: 80, op: 0.40)
        }
        .ignoresSafeArea()
    }
    private func orb(_ c: Color, size: CGFloat, x: CGFloat, y: CGFloat,
                     blur: CGFloat, op: Double) -> some View {
        Circle().fill(c).frame(width: size, height: size)
            .blur(radius: blur).opacity(op)
            .offset(x: x, y: y)
    }
}

extension View {
    /// 给一屏铺上液态玻璃背景（取代旧的 `.background(Theme.stage.ignoresSafeArea())`）。
    func appBackground() -> some View {
        self.background(AppBackground())
    }

    /// 磨砂玻璃卡片。系统 Material 真模糊 + 顶部镜面高光 + 上亮下暗发丝边 +
    /// 双层蓝灰柔投影，背后的色球会透出淡淡的蓝/粉/绿。
    func appCard(radius: CGFloat = Theme.rMd, raised: Bool = true) -> some View {
        self.glassPanel(tint: nil, radius: radius)
    }

    /// .cta 样式：玻璃蓝渐变 + 白字。
    func ctaStyle(radius: CGFloat = Theme.rMd) -> some View {
        self
            .foregroundStyle(Theme.accentInk)
            .background(Theme.accentGrad,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// 玻璃面板核心实现。tint=nil → 纯磨砂玻璃；tint!=nil → 玻璃上叠着色
    /// （不透明强调色 → 实心蓝 CTA；半透强调色 → 浅蓝高亮）。
    @ViewBuilder
    func glassPanel(tint: Color?, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        self
            .background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint) }
                    // 顶部镜面高光，让玻璃「受光」。
                    shape.fill(LinearGradient(
                        colors: [.white.opacity(0.28), .clear],
                        startPoint: .top, endPoint: .center))
                        .allowsHitTesting(false)
                }
            }
            .overlay(
                // 上亮下暗的受光发丝边。
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.22)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            )
            .clipShape(shape)
            // 双层投影：贴地接触影 + 大范围蓝灰环境影（浮起来）。
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .shadow(color: Theme.shadowSoft.opacity(0.22), radius: 18, y: 10)
    }

    /// 向后兼容：glassCard()。
    func glassCard(tint: Color? = nil, radius: CGFloat = Theme.rMd) -> some View {
        self.glassPanel(tint: tint, radius: radius)
    }

    func ctaGlassStyle() -> some View { self.tint(Theme.accent) }
}

/// 主按钮样式：按下时轻微缩放 + 压暗，给玻璃按钮真实的触感。
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// 设计稿 .pill —— accent（实心蓝）或 ghost（磨砂描边）。小状态标签。
struct Pill: View {
    enum Kind { case accent, ghost }
    let text: String
    var kind: Kind = .ghost
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .foregroundStyle(kind == .accent ? Theme.accentInk : Theme.textDim)
            .background {
                if kind == .accent {
                    Capsule().fill(Theme.accent)
                } else {
                    Capsule().fill(.regularMaterial)
                        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                }
            }
    }
}
