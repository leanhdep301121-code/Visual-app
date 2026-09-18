#if DEBUG
import AVFoundation
import CoreMedia
import ImageIO
import Foundation

/// 实时检测端到端自测 —— 模拟器没有摄像头，这里用一段打包的高尔夫视频当
/// 「虚拟摄像头」，把帧逐帧喂进与真机**完全相同**的实时检测管线
/// （`YoloPoseService` 取姿态 → `LiveSwingTracker` 状态机逐杆检测），验证
/// 实时检测本身能不能跑通、能不能检出挥杆。
///
/// 触发：启动时带环境变量 `LIVETEST=1`（自动化用，prod/无变量时完全惰性）：
///   SIMCTL_CHILD_LIVETEST=1 xcrun simctl launch <udid> com.swin.aicoach
/// 结果打到控制台，`[LiveTest]` 前缀。
///
/// 注意：这测的是**检测逻辑**（姿态 + LiveSwingTracker 状态机），不测
/// AVCaptureSession 那层摄像头硬件管线——后者在模拟器上无解（Apple 限制），
/// 真机才有。检测逻辑是真机/模拟器同一套代码。
enum LiveDetectionSelfTest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["LIVETEST"] == "1" else { return }
        Task.detached(priority: .userInitiated) { await run() }
    }

    /// 用哪段视频当虚拟摄像头：默认打包的 tiger_driver；可用 LIVETEST_VIDEO 指定别的资源名。
    private static var videoResource: String {
        ProcessInfo.processInfo.environment["LIVETEST_VIDEO"] ?? "tiger_driver"
    }

    static func run() async {
        let name = videoResource
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp4") else {
            print("[LiveTest] ❌ \(name).mp4 没打包进 app — 跳过")
            return
        }
        print("[LiveTest] ▶︎ 虚拟摄像头：\(name).mp4 → 实时检测管线")

        // 与真机相同的实时检测组件
        let pose: PoseService = (try? YoloPoseService()) ?? VisionPoseService()
        let tracker = LiveSwingTracker()
        let sink = DetectionSink()
        tracker.onSwingDetected = { frames, events in
            sink.record(clipFrames: frames.count, events: events, note: tracker.lastEmitOutcome)
        }

        // 读帧（与 VideoAnalyzer 相同：按 preferredTransform 取正确朝向）
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            print("[LiveTest] ❌ 视频无视频轨"); return
        }
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let frameRate = (try? await track.load(.nominalFrameRate)) ?? 30
        let ori = cgOrientation(for: transform)

        guard let reader = try? AVAssetReader(asset: asset) else {
            print("[LiveTest] ❌ AVAssetReader 初始化失败"); return
        }
        let out = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(out) else { print("[LiveTest] ❌ 无法挂 reader output"); return }
        reader.add(out)
        guard reader.startReading() else {
            print("[LiveTest] ❌ reader 启动失败: \(reader.error?.localizedDescription ?? "?")"); return
        }

        var n = 0
        var allPoses: [PoseFrame] = []
        while let buf = out.copyNextSampleBuffer() {
            if let p = pose.extractSync(buf, cgOrientation: ori) {
                allPoses.append(p)
                tracker.ingest(p)          // ← 真机 captureOutput 走的就是这条（经 onPoseUpdate）
            }
            n += 1
        }
        // emit 是在后台串行队列上做整段解码的，给它点时间收尾
        try? await Task.sleep(for: .seconds(3))

        print("[LiveTest] ✅ 实时路径完成 — 总帧 \(n)，有姿态 \(allPoses.count)，"
              + "帧率 \(String(format: "%.1f", frameRate))fps，实时检出挥杆 \(sink.count) 次")
        sink.dump()

        // —— 诊断：模型到底有没有「看见」挥杆事件 ——
        // 全片检测器（上传路径，逐类 argmax，不靠 no-event 阈值）做对照 + 打印
        // 每个挥杆事件类在整段里的最高概率。若各事件最高概率都接近 0（no-event
        // 总赢）→ 是输入/视频/帧率问题；若 Address/Top/Impact/Finish 能到 0.4+ →
        // 模型看得见，实时状态机只是需要合适的输入（足够 setup 帧、对的帧率）。
        let core = try? PoseTCNEventDetectorCore()
        guard let core else { print("[LiveTest] (诊断) core 初始化失败"); return }
        let labels = ["Address","Toe-up","Mid-bs","Top","Mid-ds","Impact","Mid-fl","Finish","no-ev"]
        var maxProb = [Float](repeating: 0, count: 9)
        var argmaxFrame = [Int](repeating: -1, count: 9)
        let W = 64, S = 32
        var start = 0
        while start < allPoses.count {
            let end = min(start + W, allPoses.count)
            let win = Array(allPoses[start..<end])
            let prev = start > 0 ? allPoses[start - 1] : nil
            let probs = core.inferWindow(win, previousPose: prev)   // (win, 9) softmax
            for (t, p) in probs.enumerated() {
                for c in 0..<9 where p[c] > maxProb[c] { maxProb[c] = p[c]; argmaxFrame[c] = start + t }
            }
            if end == allPoses.count { break }
            start += S
        }
        let summary = (0..<9).map { "\(labels[$0])=\(String(format: "%.2f", maxProb[$0]))@\(argmaxFrame[$0])" }.joined(separator: " ")
        print("[LiveTest] 🔬 各类最高概率(@帧): \(summary)")
        if let fc = try? PoseTCNEventDetector().detect(allPoses) {
            print("[LiveTest] 🔬 全片检测器 8事件帧位: \(fc.frames)  handed=\(fc.handedness)")
        }
    }

    /// 收集检测结果（线程安全的小桶，避免闭包跨线程捕获可变量的并发告警）。
    private final class DetectionSink: @unchecked Sendable {
        private let lock = NSLock()
        private var swings: [(clip: Int, frames: [Int], note: String)] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return swings.count }
        func record(clipFrames: Int, events: SwingEvents, note: String) {
            lock.lock(); swings.append((clipFrames, events.frames, note)); lock.unlock()
            print("[LiveTest] 🏌️ 检出一杆 — 片段 \(clipFrames) 帧，8事件帧位 \(events.frames)  | \(note)")
        }
        func dump() {
            lock.lock(); let s = swings; lock.unlock()
            if s.isEmpty {
                print("[LiveTest] ⚠️ 没检出任何挥杆 — 看是姿态(YOLO)没出关键点，还是状态机阈值问题")
            }
        }
    }

    /// 解 preferredTransform → CGImagePropertyOrientation（与 VideoAnalyzer 同逻辑）。
    private static func cgOrientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        let eps: CGFloat = 0.01
        func eq(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) < eps }
        if eq(t.a, 0)  && eq(t.b, 1)  && eq(t.c, -1) && eq(t.d, 0)  { return .right }
        if eq(t.a, 0)  && eq(t.b, -1) && eq(t.c, 1)  && eq(t.d, 0)  { return .left }
        if eq(t.a, 1)  && eq(t.b, 0)  && eq(t.c, 0)  && eq(t.d, 1)  { return .up }
        if eq(t.a, -1) && eq(t.b, 0)  && eq(t.c, 0)  && eq(t.d, -1) { return .down }
        if eq(t.a, -1) && eq(t.b, 0)  && eq(t.c, 0)  && eq(t.d, 1)  { return .upMirrored }
        if eq(t.a, 1)  && eq(t.b, 0)  && eq(t.c, 0)  && eq(t.d, -1) { return .downMirrored }
        if eq(t.a, 0)  && eq(t.b, -1) && eq(t.c, -1) && eq(t.d, 0)  { return .leftMirrored }
        if eq(t.a, 0)  && eq(t.b, 1)  && eq(t.c, 1)  && eq(t.d, 0)  { return .rightMirrored }
        return .up
    }
}
#endif
