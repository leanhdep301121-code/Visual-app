import SwiftUI

/// 启动页（设计稿第 1 屏）。app 启动时加载 CoreML 模型有 1-2 秒白屏，用这个
/// 品牌启动页盖住：青绿渐变圆角方块 logo + "GoSwin" + 标语，深色渐变背景。
/// 加载就绪或固定时长后淡出。
struct SplashView: View {
    @State private var glow = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 18) {
                // 青绿渐变圆角方块 logo + 发光
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Theme.accentGrad)
                    .frame(width: 88, height: 88)
                    .overlay(Image(systemName: "figure.golf").font(.system(size: 42, weight: .semibold)).foregroundStyle(.white))
                    .shadow(color: Theme.accentGlow, radius: glow ? 40 : 20)
                    .scaleEffect(glow ? 1.0 : 0.96)

                VStack(spacing: 6) {
                    Text("GoSwin")
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(Theme.text)
                    Text("端上实时挥杆教练")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
    }
}
