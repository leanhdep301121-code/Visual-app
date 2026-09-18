import CoreImage
import CoreML
import CoreMedia
import Foundation
import Observation
import Vision

/// Pose extractor backed by yolo11n-pose-golf.mlmodel (distilled from YOLO11m on GolfDB).
/// Drops in behind the `PoseService` protocol; CameraService picks this over
/// VisionPoseService at startup if the .mlmodelc is bundled.
@Observable
final class YoloPoseService: PoseService, @unchecked Sendable {
    private(set) var latestPose: PoseFrame?
    var onPoseUpdate: ((PoseFrame) -> Void)?

    private let vnModel: VNCoreMLModel
    private let queue = DispatchQueue(label: "com.swin.pose.yolo", qos: .userInitiated)
    private let lock = NSLock()
    private var isProcessing = false
    /// Last published (jump-filtered) pose — used to reject background-induced
    /// keypoint teleports. Accessed only on `queue` (serial), so no extra lock.
    private var lastFilteredPose: PoseFrame?

    /// Model input side length (square). Read from the loaded model's image
    /// constraint in `init` so 192² (COCO) and 320² (golf-distilled) both work
    /// — the letterbox inverse in `decode` depends on it.
    private var inputSize: CGFloat = 192
    private let objConfThreshold: Float = 0.3
    private let kpVisThreshold: Float = 0.3

    private static var didLogBufferDims = false

    init() throws {
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        // 模拟器的 MPS/GPU 后端不被支持：走 .all 会每帧抛
        // "E5RT ... MpsGraph backend validation on incompatible OS"，
        // 这种持续的 Metal 异常会拖垮 SwiftUI 共用的渲染上下文（→ 整屏白屏）。
        // 强制 CPU（同 PoseTCN），换设备上不变。
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        // Model bundled as `yolo11n-pose` (currently the golf-distilled 320²
        // variant, trained on golf data). `inputSize` is read from whatever
        // loads, so a 192² COCO model would also work if swapped back in.
        guard let url = Bundle.main.url(forResource: "yolo11n-pose", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "yolo11n-pose", withExtension: "mlpackage")
            ?? Bundle.main.url(forResource: "yolo11n-pose-golf", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "yolo11n-pose-golf", withExtension: "mlpackage")
        else {
            throw NSError(
                domain: "Swin.YoloPose",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "no yolo11n-pose model bundled"]
            )
        }
        let mlmodel = try MLModel(contentsOf: url, configuration: config)
        self.vnModel = try VNCoreMLModel(for: mlmodel)
        // Read the model's input side length so the letterbox inverse matches
        // (must be after vnModel init — can't touch self before then).
        if let c = mlmodel.modelDescription.inputDescriptionsByName["image"]?.imageConstraint {
            inputSize = CGFloat(c.pixelsWide)
        }
        print("[YoloPoseService] using model: \(url.lastPathComponent) input=\(Int(inputSize))²")
    }

    func submit(_ buffer: CMSampleBuffer, orientation: CameraOrientation) {
        lock.lock()
        if isProcessing { lock.unlock(); return }
        isProcessing = true
        lock.unlock()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { clearBusy(); return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        let cgOrientation: CGImagePropertyOrientation =
            (orientation == .backPortrait) ? .right : .leftMirrored

        // Compute rotatedSize from the actual buffer instead of hardcoding —
        // hardcoded (1080,1920) was wrong when the sensor delivers a different
        // orientation, breaking the letterbox inverse and the iso divisor.
        let bw = CVPixelBufferGetWidth(pixelBuffer)
        let bh = CVPixelBufferGetHeight(pixelBuffer)
        let rotates90 = (cgOrientation == .right || cgOrientation == .left
                         || cgOrientation == .leftMirrored || cgOrientation == .rightMirrored)
        let rotatedSize = rotates90
            ? CGSize(width: bh, height: bw)
            : CGSize(width: bw, height: bh)
        if !YoloPoseService.didLogBufferDims {
            YoloPoseService.didLogBufferDims = true
            dbg(tag: "track", String(format: "buffer=%dx%d cgOrient=%d rotatedSize=%.0fx%.0f",
                bw, bh, cgOrientation.rawValue, rotatedSize.width, rotatedSize.height))
        }

        queue.async { [weak self] in
            guard let self else { return }
            defer { self.clearBusy() }

            let request = VNCoreMLRequest(model: self.vnModel)
            request.imageCropAndScaleOption = .scaleFit   // letterbox-pad to model input

            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: cgOrientation,
                options: [:]
            )
            do {
                try handler.perform([request])
            } catch {
                return
            }

            guard let result = request.results?.first as? VNCoreMLFeatureValueObservation,
                  let raw = result.featureValue.multiArrayValue,
                  let pose = self.decode(raw: raw, rotatedSize: rotatedSize, timestamp: timestamp)
            else { return }

            let filtered = self.filterJumps(pose)
            DispatchQueue.main.async {
                self.latestPose = filtered
                self.onPoseUpdate?(filtered)
            }
        }
    }

    /// Reject per-keypoint "teleports" caused by a busy background (a joint
    /// snapping onto a bystander / pole / shadow). A genuine fast move — wrist
    /// at impact — arrives at HIGH confidence; a spurious jump is almost always
    /// a confidence dip + a large displacement. So we only veto joints that
    /// move a lot AND have dropped confidence, holding their previous position.
    /// Runs on `queue` (serial), so `lastFilteredPose` needs no lock.
    private func filterJumps(_ pose: PoseFrame) -> PoseFrame {
        guard let prev = lastFilteredPose,
              prev.keypoints.count == pose.keypoints.count else {
            lastFilteredPose = pose
            return pose
        }
        let maxJump: Float = 0.18      // ~18% of frame height in one frame
        let trustConf: Float = 0.6     // above this we trust even a big move
        var kp = pose.keypoints
        var cf = pose.confidences
        for j in 0..<kp.count {
            let dx = kp[j].x - prev.keypoints[j].x
            let dy = kp[j].y - prev.keypoints[j].y
            if (dx * dx + dy * dy).squareRoot() > maxJump && cf[j] < trustConf {
                kp[j] = prev.keypoints[j]               // hold last good position
                cf[j] = min(cf[j], prev.confidences[j]) * 0.9
            }
        }
        let filtered = PoseFrame(timestamp: pose.timestamp, keypoints: kp,
                                 confidences: cf, isoNormalized: pose.isoNormalized,
                                 imageAspect: pose.imageAspect)
        lastFilteredPose = filtered
        return filtered
    }

    private func clearBusy() {
        lock.lock(); isProcessing = false; lock.unlock()
    }

    /// Force-clear the in-flight guard. Called from CameraService when a
    /// session restart can't trust that the previous inference's `defer`
    /// actually ran (background suspend, view recreation). Without this,
    /// a stuck `isProcessing = true` silently drops every subsequent
    /// frame at the lock check, killing live detection.
    func forceClearBusy() {
        lock.lock(); isProcessing = false; lock.unlock()
    }

    func extractSync(_ buffer: CMSampleBuffer, cgOrientation: CGImagePropertyOrientation) -> PoseFrame? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)

        // For uploaded videos we don't know the original pre-rotation size, so use the
        // pixel buffer's dimensions. After Vision applies orientation those may be swapped.
        let bw = CVPixelBufferGetWidth(pixelBuffer)
        let bh = CVPixelBufferGetHeight(pixelBuffer)
        // If orientation rotates 90°, the rotated size is (height, width)
        let rotates90 = (cgOrientation == .right || cgOrientation == .left
                         || cgOrientation == .leftMirrored || cgOrientation == .rightMirrored)
        let rotatedSize = rotates90
            ? CGSize(width: bh, height: bw)
            : CGSize(width: bw, height: bh)

        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: cgOrientation,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let result = request.results?.first as? VNCoreMLFeatureValueObservation,
              let raw = result.featureValue.multiArrayValue
        else { return nil }
        return decode(raw: raw, rotatedSize: rotatedSize, timestamp: timestamp)
    }

    /// raw shape: (1, 56, n_anchors). Channels: [cx, cy, w, h, obj_conf, kp0_x, kp0_y, kp0_v, ..., kp16_x, kp16_y, kp16_v]
    /// All bbox + keypoint coords are in the model input pixel space (192×192, after letterbox).
    private func decode(
        raw: MLMultiArray,
        rotatedSize: CGSize,
        timestamp: CMTime
    ) -> PoseFrame? {
        guard raw.shape.count == 3, raw.dataType == .float32 else { return nil }
        let nChannels = raw.shape[1].intValue
        let nAnchors  = raw.shape[2].intValue
        guard nChannels == 56, nAnchors > 0 else { return nil }

        let buffer = raw.dataPointer.bindMemory(to: Float.self, capacity: raw.count)
        let strides = raw.strides.map { $0.intValue }
        let stC = strides[1]
        let stA = strides[2]

        // Find the anchor with the highest objectness (channel 4)
        var bestAnchor = 0
        var bestObj: Float = -.infinity
        let objBase = 4 * stC
        for a in 0..<nAnchors {
            let v = buffer[objBase + a * stA]
            if v > bestObj { bestObj = v; bestAnchor = a }
        }
        if bestObj < objConfThreshold { return nil }

        // Letterbox inverse: model input was scaleFit'd from rotatedSize → 192×192
        let s = min(inputSize / rotatedSize.width, inputSize / rotatedSize.height)
        let padX = (Float(inputSize) - Float(rotatedSize.width)  * Float(s)) / 2
        let padY = (Float(inputSize) - Float(rotatedSize.height) * Float(s)) / 2
        let invScale = 1 / Float(s)

        var keypoints   = [SIMD2<Float>](repeating: .zero, count: 17)
        var confidences = [Float](repeating: 0, count: 17)

        // Anisotropic normalization: x divided by oriented width, y by oriented
        // height. Keypoints end up in [0,1]×[0,1], matching the Vision pose
        // convention. The renderer can multiply by display width / height
        // directly. PoseTCN's feature extractor compensates via `imageAspect`
        // to recover pixel-ratio units before computing the torso scale.
        let invW = 1 / Float(rotatedSize.width)
        let invH = 1 / Float(rotatedSize.height)

        for j in 0..<17 {
            let kxBase = (5 + j * 3 + 0) * stC
            let kyBase = (5 + j * 3 + 1) * stC
            let kvBase = (5 + j * 3 + 2) * stC

            let kx = buffer[kxBase + bestAnchor * stA]
            let ky = buffer[kyBase + bestAnchor * stA]
            let kv = buffer[kvBase + bestAnchor * stA]

            let origX = (kx - padX) * invScale
            let origY = (ky - padY) * invScale
            keypoints[j] = SIMD2<Float>(origX * invW, origY * invH)
            confidences[j] = max(0, min(1, kv))
        }

        return PoseFrame(timestamp: timestamp,
                         keypoints: keypoints,
                         confidences: confidences,
                         isoNormalized: false,
                         imageAspect: Float(rotatedSize.width / rotatedSize.height))
    }
}
