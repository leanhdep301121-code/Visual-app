import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(FeedbackOrchestrator.self) private var feedback
    @Environment(CameraService.self) private var camera
    /// 启动页盖在最上层，盖住启动时加载 CoreML 的白屏，短暂停留后淡出。
    @State private var showSplash = true
    /// 选中的标签页。初始值可由启动环境变量 UITAB 指定（仅用于自动化截图：
    /// `SIMCTL_CHILD_UITAB=1 xcrun simctl launch …` 直接打开第 2 个 tab）。
    @State private var tab = Int(ProcessInfo.processInfo.environment["UITAB"] ?? "") ?? 0
    #if DEBUG
    /// 调试：OPENANALYSIS=1 启动时用打包视频跑分析、直接打开分析页（看 UI 用）。
    @State private var debugReport: SwingReport?
    /// 调试：OPENRECORD=1 启动直接打开实时录制屏（模拟器走虚拟摄像头）。
    /// 注意：fullScreenCover 用"初始即 true"呈现不可靠，所以初值 false，
    /// 在 onAppear 之后再置 true（见下方 .task）。
    @State private var debugRecord = false
    /// 调试：CAPTURELAB=1 启动直接打开拍摄实验台（多摄/电影/对焦/光影，真机用）。
    @State private var debugCaptureLab = ProcessInfo.processInfo.environment["CAPTURELAB"] == "1"
    /// 调试：HOLOGRAM=1 启动直接打开 AR 职业挥杆全息(模拟器走回放预览)。
    @State private var debugHologram = false
    #endif

    @ViewBuilder
    private var mainContent: some View {
        if feedback.userProfile.onboarded {
            // 极简两标签：练习 = 开始挥杆(实时·主) + 最近 + 全部历史 +
            // 上传(backup)；我的 = 设置。历史与上传从练习页进，不占 tab。
            TabView(selection: $tab) {
                PracticeHomeView()
                    .tabItem { Label("练习", systemImage: "figure.golf") }.tag(0)
                ProfileView()
                    .tabItem { Label("我的", systemImage: "person.crop.circle") }.tag(1)
            }
            .tint(Theme.accent)
        } else {
            AppOnboardingView()
        }
    }

    var body: some View {
        ZStack {
            mainContent

            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .task {
                        // 给模型加载留点时间，再淡出（约 1.6 秒）。
                        try? await Task.sleep(for: .seconds(1.6))
                        withAnimation(.easeOut(duration: 0.45)) { showSplash = false }
                    }
            }
        }
        #if DEBUG
        .task(id: "debug-open-record") {
            // Present RecordView AFTER the view is in the hierarchy — presenting
            // a fullScreenCover with isPresented already true at init renders
            // unreliably (sometimes shows the view underneath instead).
            guard ProcessInfo.processInfo.environment["OPENRECORD"] == "1" else { return }
            try? await Task.sleep(for: .seconds(1.8))   // let the splash fade first
            debugRecord = true
        }
        .task(id: "debug-analysis") {
            guard ProcessInfo.processInfo.environment["OPENANALYSIS"] == "1", debugReport == nil
            else { return }
            // ANALYZEVIDEO=<file in Documents>: analyze an arbitrary pushed clip
            // (real-footage pipeline tests); default = bundled tiger_driver.
            let url: URL
            if let name = ProcessInfo.processInfo.environment["ANALYZEVIDEO"] {
                url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(name)
            } else if let bundled = Bundle.main.url(forResource: "tiger_driver", withExtension: "mp4") {
                url = bundled
            } else { return }
            let pose: PoseService = (try? YoloPoseService()) ?? VisionPoseService()
            let det: any EventDetector = (try? PoseTCNEventDetector()) ?? HeuristicEventDetector()
            let analyzer = VideoAnalyzer(poseService: pose, eventDetector: det)
            await analyzer.analyze(url: url, viewpoint: .downTheLine, handedness: nil)
            debugReport = analyzer.report
        }
        .fullScreenCover(isPresented: Binding(
            get: { debugReport != nil },
            set: { if !$0 { debugReport = nil } }
        )) {
            if let r = debugReport { ProAnalysisView(report: r).environment(feedback) }
        }
        .fullScreenCover(isPresented: $debugRecord) {
            RecordView().environment(feedback).environment(camera)
        }
        .fullScreenCover(isPresented: $debugCaptureLab) {
            CaptureLabView()
        }
        .task(id: "debug-hologram") {
            guard ProcessInfo.processInfo.environment["HOLOGRAM"] == "1" else { return }
            try? await Task.sleep(for: .seconds(1.8))
            debugHologram = true
        }
        .fullScreenCover(isPresented: $debugHologram) {
            SwingHologramView()
        }
        #endif
    }
}

/// First-launch onboarding: a couple of basics (handedness — used for lead/trail;
/// height — stored for the future body-type work) then an upload of a swing the
/// user already has, which we analyze to seed their profile (focus candidates +
/// an INTERNAL level we never show them). Skippable.
struct AppOnboardingView: View {
    @Environment(FeedbackOrchestrator.self) private var feedback
    @State private var handedness = "right"

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                Spacer()
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Theme.accentGrad)
                    .frame(width: 96, height: 96)
                    .overlay(Image(systemName: "figure.golf")
                        .font(.system(size: 46, weight: .semibold)).foregroundStyle(.white))
                    .shadow(color: Theme.accent.opacity(0.4), radius: 24, y: 12)
                    .padding(.bottom, 22)
                Text("欢迎来到 GoSwin")
                    .font(Theme.display(28, .bold)).foregroundStyle(Theme.ink)
                Text("对准你的挥杆，实时帮你看问题")
                    .font(.subheadline).foregroundStyle(Theme.textDim).padding(.top, 6)

                Spacer()

                VStack(alignment: .leading, spacing: 10) {
                    Text("你用哪只手打球？")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Picker("", selection: $handedness) {
                        Text("右手").tag("right")
                        Text("左手").tag("left")
                    }
                    .pickerStyle(.segmented)
                }
                .padding(16).glassCard(radius: 18).padding(.bottom, 14)

                Button {
                    feedback.completeOnboarding(report: nil, handedness: handedness, heightCm: nil)
                } label: {
                    Text("开始")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
                        .foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.accentGrad))
                        .shadow(color: Theme.accent.opacity(0.35), radius: 16, y: 8)
                }
                .buttonStyle(.pressable)
            }
            .padding(24)
        }
    }

}

#Preview {
    ContentView()
        .environment(CameraService())
        .environment(FeedbackOrchestrator())
}
