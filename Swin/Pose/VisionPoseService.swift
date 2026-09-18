import CoreMedia
import Foundation
import ImageIO
import Observation
import Vision

@Observable
final class VisionPoseService: PoseService, @unchecked Sendable {
    private(set) var latestPose: PoseFrame?
    var onPoseUpdate: ((PoseFrame) -> Void)?

    private let queue = DispatchQueue(label: "com.swin.pose.vision", qos: .userInitiated)
    private let lock = NSLock()
    private var isProcessing = false

    private static let cocoOrder: [VNHumanBodyPoseObservation.JointName] = [
        .nose,
        .leftEye, .rightEye,
        .leftEar, .rightEar,
        .leftShoulder, .rightShoulder,
        .leftElbow, .rightElbow,
        .leftWrist, .rightWrist,
        .leftHip, .rightHip,
        .leftKnee, .rightKnee,
        .leftAnkle, .rightAnkle,
    ]

    func submit(_ buffer: CMSampleBuffer, orientation: CameraOrientation) {
        lock.lock()
        if isProcessing { lock.unlock(); return }
        isProcessing = true
        lock.unlock()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else {
            clearBusy()
            return
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        let cgOrientation: CGImagePropertyOrientation =
            (orientation == .backPortrait) ? .right : .leftMirrored
        // Aspect ratio of the ORIENTED frame (after Vision applies cgOrientation),
        // for PoseTCN feature-extractor compensation. Buffer is landscape; if we
        // rotate 90° for portrait orientation, oriented W = buffer H.
        let bw = CVPixelBufferGetWidth(pixelBuffer)
        let bh = CVPixelBufferGetHeight(pixelBuffer)
        let rotates90 = (cgOrientation == .right || cgOrientation == .left
                         || cgOrientation == .leftMirrored || cgOrientation == .rightMirrored)
        let orientedW = rotates90 ? bh : bw
        let orientedH = rotates90 ? bw : bh
        let aspect = Float(orientedW) / Float(max(1, orientedH))

        queue.async { [weak self] in
            guard let self else { return }
            defer { self.clearBusy() }

            let request = VNDetectHumanBodyPoseRequest()
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
            guard let observation = request.results?.first else { return }

            var keypoints = [SIMD2<Float>](repeating: .zero, count: PoseFrame.jointCount)
            var confidences = [Float](repeating: 0, count: PoseFrame.jointCount)

            for (i, joint) in Self.cocoOrder.enumerated() {
                guard
                    let point = try? observation.recognizedPoint(joint),
                    point.confidence > 0.05
                else { continue }
                // Vision normalized coords: (0,0) lower-left → flip Y for upper-left origin
                keypoints[i] = SIMD2<Float>(
                    Float(point.location.x),
                    Float(1 - point.location.y)
                )
                confidences[i] = point.confidence
            }

            let pose = PoseFrame(
                timestamp: timestamp,
                keypoints: keypoints,
                confidences: confidences,
                isoNormalized: false,
                imageAspect: aspect
            )
            DispatchQueue.main.async {
                self.latestPose = pose
                self.onPoseUpdate?(pose)
            }
        }
    }

    private func clearBusy() {
        lock.lock(); isProcessing = false; lock.unlock()
    }

    func extractSync(_ buffer: CMSampleBuffer, cgOrientation: CGImagePropertyOrientation) -> PoseFrame? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        let bw = CVPixelBufferGetWidth(pixelBuffer)
        let bh = CVPixelBufferGetHeight(pixelBuffer)
        let rotates90 = (cgOrientation == .right || cgOrientation == .left
                         || cgOrientation == .leftMirrored || cgOrientation == .rightMirrored)
        let orientedW = rotates90 ? bh : bw
        let orientedH = rotates90 ? bw : bh
        let aspect = Float(orientedW) / Float(max(1, orientedH))

        let request = VNDetectHumanBodyPoseRequest()
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
        guard let observation = request.results?.first else { return nil }

        var keypoints = [SIMD2<Float>](repeating: .zero, count: PoseFrame.jointCount)
        var confidences = [Float](repeating: 0, count: PoseFrame.jointCount)
        for (i, joint) in Self.cocoOrder.enumerated() {
            guard let p = try? observation.recognizedPoint(joint), p.confidence > 0.05 else { continue }
            keypoints[i] = SIMD2<Float>(Float(p.location.x), Float(1 - p.location.y))
            confidences[i] = p.confidence
        }
        return PoseFrame(timestamp: timestamp,
                         keypoints: keypoints,
                         confidences: confidences,
                         isoNormalized: false,
                         imageAspect: aspect)
    }
}
