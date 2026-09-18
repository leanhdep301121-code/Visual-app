import AVFoundation
import CoreML
import Foundation
import Vision

/// Clubhead track detected over a swing clip by the distilled on-device
/// club detector (`ClubDetectYOLO11n.mlpackage`, YOLO11l→n, see ModelGarage
/// `clubhead/CLUBDETECT_N_EVAL.md`). Normalized [0,1] top-left coords.
///
/// Per the eval: the student is reliable on salient clubheads (conf ≥0.25)
/// but NOT a per-frame guarantee — consumers must treat this as sparse
/// anchor points (visual track / tempo), never as dense ground truth.
struct ClubTrack: Codable, Sendable {
    struct Point: Codable, Sendable, Hashable {
        let x: Float          // clubhead center, normalized top-left
        let y: Float
        let confidence: Float
        let timeSeconds: Double   // media time in the clip
    }
    let points: [Point]
    /// Fraction of scanned frames that produced an accepted detection.
    let coverage: Float
}

/// Offline clubhead detector: runs the distilled YOLO11n over a clip's frames
/// (strided), keeps the best clubhead box per frame, and applies a temporal
/// gate so one-frame jumps (spectator hands, sign corners) are dropped.
final class ClubDetectService {
    private let vnModel: VNCoreMLModel

    init() throws {
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly     // sim MPS unsupported (same as YoloPoseService)
        #else
        config.computeUnits = .all
        #endif
        guard let url = Bundle.main.url(forResource: "ClubDetectYOLO11n", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "ClubDetectYOLO11n", withExtension: "mlpackage")
        else {
            throw NSError(domain: "Swin.ClubDetect", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "ClubDetectYOLO11n not bundled"])
        }
        let mlmodel = try MLModel(contentsOf: url, configuration: config)
        self.vnModel = try VNCoreMLModel(for: mlmodel)
    }

    /// Scan the clip and return the clubhead track. `stride` skips frames for
    /// speed (2 ≈ 15 fps effective on 30 fps clips — plenty for a track).
    func detect(in url: URL,
                orientation: CGImagePropertyOrientation,
                stride: Int = 2,
                minConfidence: Float = 0.25) async -> ClubTrack? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var points: [ClubTrack.Point] = []
        var scanned = 0
        var frameIdx = 0
        var lastAccepted: (t: Double, x: Float, y: Float)? = nil

        while let sample = output.copyNextSampleBuffer() {
            defer { frameIdx += 1 }
            if frameIdx % max(1, stride) != 0 { continue }
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            scanned += 1
            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))

            let request = VNCoreMLRequest(model: vnModel)
            request.imageCropAndScaleOption = .scaleFill
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation)
            try? handler.perform([request])

            guard let objs = request.results as? [VNRecognizedObjectObservation] else { continue }
            let heads = objs.filter { obs in
                obs.labels.first?.identifier == "clubhead" && obs.confidence >= minConfidence
            }
            guard let best = heads.max(by: { $0.confidence < $1.confidence }) else { continue }

            // Vision bbox is normalized lower-left origin → flip y for our
            // top-left convention; take the box center.
            let bb = best.boundingBox
            let x = Float(bb.midX)
            let y = Float(1 - bb.midY)

            // Temporal gate: clubhead can move fast but not teleport — reject
            // > 0.30 normalized jump within 0.15 s of the last accepted point.
            if let last = lastAccepted, t - last.t < 0.15 {
                let d = ((x - last.x) * (x - last.x) + (y - last.y) * (y - last.y)).squareRoot()
                if d > 0.30 { continue }
            }
            lastAccepted = (t, x, y)
            points.append(.init(x: x, y: y, confidence: best.confidence, timeSeconds: t))
        }
        guard points.count >= 3 else { return nil }
        return ClubTrack(points: points,
                         coverage: scanned > 0 ? Float(points.count) / Float(scanned) : 0)
    }
}
