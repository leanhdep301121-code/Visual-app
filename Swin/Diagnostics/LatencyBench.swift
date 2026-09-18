import CoreML
import CoreVideo
import Foundation
import Vision

/// One-shot startup benchmark for the on-device CoreML models. Logs to Xcode
/// console so we can confirm Pose-TCN < 5 ms / YOLO ≥ 30 fps targets on real
/// silicon. Runs on a background thread so it doesn't block app launch.
enum LatencyBench {
    static func runOnce() {
        Task.detached(priority: .background) {
            await runYolo()
            await runPoseTCN()
        }
    }

    // MARK: - YOLO11n-pose

    private static func runYolo() async {
        guard let url = Bundle.main.url(forResource: "yolo11n-pose", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "yolo11n-pose", withExtension: "mlpackage")
        else {
            print("[Latency] yolo11n-pose model not bundled — skipped")
            return
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let mlmodel = try? MLModel(contentsOf: url, configuration: config),
              let vnModel = try? VNCoreMLModel(for: mlmodel)
        else {
            print("[Latency] yolo: failed to load")
            return
        }

        guard let pixelBuffer = makePixelBuffer(width: 1080, height: 1920) else { return }
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .right, options: [:])

        // warm-up
        for _ in 0..<3 { _ = try? handler.perform([request]) }

        let n = 20
        let started = Date()
        for _ in 0..<n {
            // VNImageRequestHandler caches once perform is called; rebuild for fair timing
            let h = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                          orientation: .right, options: [:])
            _ = try? h.perform([request])
        }
        let avgMs = Date().timeIntervalSince(started) * 1000 / Double(n)
        let fps = 1000.0 / avgMs
        print(String(format: "[Latency] YOLO11n-pose · %.2f ms/frame · %.1f fps · target 30+",
                     avgMs, fps))
    }

    // MARK: - Pose-TCN v3.1

    private static func runPoseTCN() async {
        guard let url = Bundle.main.url(forResource: "PoseTCN_v3_1", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "PoseTCN_v3_1", withExtension: "mlpackage")
        else {
            print("[Latency] PoseTCN_v3_1 model not bundled — skipped")
            return
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let mlmodel = try? MLModel(contentsOf: url, configuration: config) else {
            print("[Latency] posetcn: failed to load")
            return
        }
        // v3.1 input dim = 102 (51 pos+conf + 51 frame-to-frame Δ).
        guard let arr = try? MLMultiArray(shape: [1, 64, 102], dataType: .float32) else { return }
        let dst = arr.dataPointer.bindMemory(to: Float.self, capacity: 64 * 102)
        for i in 0..<(64 * 102) { dst[i] = Float.random(in: -2 ... 2) }

        let provider = try? MLDictionaryFeatureProvider(dictionary: ["pose_seq": arr])
        guard let provider else { return }

        // warm-up
        for _ in 0..<3 { _ = try? await mlmodel.prediction(from: provider) }

        let n = 50
        let started = Date()
        for _ in 0..<n {
            _ = try? await mlmodel.prediction(from: provider)
        }
        let avgMs = Date().timeIntervalSince(started) * 1000 / Double(n)
        print(String(format: "[Latency] PoseTCN_v3_1 · %.2f ms/window (T=64) · target <5",
                     avgMs))
    }

    // MARK: - helpers

    private static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pb
        )
        guard status == kCVReturnSuccess, let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        if let base = CVPixelBufferGetBaseAddress(buf) {
            memset(base, 128, CVPixelBufferGetDataSize(buf))   // mid-gray
        }
        return buf
    }
}
