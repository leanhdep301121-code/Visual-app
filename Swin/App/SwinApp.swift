import SwiftUI

@main
struct SwinApp: App {
    @State private var camera = CameraService()
    @State private var feedback = FeedbackOrchestrator()

    init() {
        AppLanguage.followSystem()   // 语言跟随系统（已移除手动选择），清旧覆盖
        #if !targetEnvironment(simulator)
        // 模拟器跳过：基准在 sim 上无意义，而它用 .all 跑 YOLO/PoseTCN 会在
        // 启动就刷 "E5RT...MpsGraph backend validation on incompatible OS"，
        // 这种持续 Metal 异常会拖垮 SwiftUI 渲染上下文（→ 整屏白屏）。
        LatencyBench.runOnce()
        #endif
        if ProcessInfo.processInfo.environment["CAPPROBE"] == "1" {
            CapabilityProbe.runOnce()            // CAPPROBE=1：拍摄杆功能的真机能力报告
        }
        #if DEBUG
        LiveDetectionSelfTest.runIfRequested()   // LIVETEST=1：视频当虚拟摄像头跑实时检测
        MultiCamProbe.runIfRequested()           // MULTICAM=1：真机量广角+长焦并发可行性/成本/热
        RetentionSelfTest.runIfRequested()       // RETENTIONTEST=1：动态保存 keep-set 纯逻辑自检
        BallFlightSelfTest.runIfRequested()      // BALLFIT=1：3D 弹道拟合器合成数据回环自证
        #endif
        Self.cleanupTransientCaches()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(camera)
                .environment(feedback)
                // 设计=液态玻璃浅色风，全局强制浅色：系统 Material 才会渲染成
                // 白色磨砂玻璃（深色下会变成深色磨砂），导航大标题也才是近黑可读。
                // 视频/相机屏（Record、ProAnalysis）自身再强制深色。
                .preferredColorScheme(.light)
                .statusBarHidden(true)
        }
    }

    /// Sweep transient on-disk caches at launch. iOS NEVER auto-cleans these,
    /// so without this they accumulate forever and chip away at user
    /// storage:
    ///   - Documents/replays/   (uploaded videos copied in by the old
    ///                           PhotosPicker replay flow)
    ///   - tmp/                 (TransferableMovie copies from UploadView)
    ///
    /// We keep nothing in replays/ because that feature was removed.
    private static func cleanupTransientCaches() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let replays = docs.appendingPathComponent("replays", isDirectory: true)
        if fm.fileExists(atPath: replays.path) {
            try? fm.removeItem(at: replays)
        }
        // Clean any leftover *.mov / *.mp4 in tmp/ from prior Upload picks.
        let tmp = fm.temporaryDirectory
        if let entries = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for entry in entries {
                let ext = entry.pathExtension.lowercased()
                if ext == "mov" || ext == "mp4" {
                    try? fm.removeItem(at: entry)
                }
            }
        }
    }
}
