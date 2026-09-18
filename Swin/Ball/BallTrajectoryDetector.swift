import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Vision

/// Wraps Apple's `VNDetectTrajectoriesRequest` to detect the golf ball
/// trajectory in the frames immediately after the Impact event.
///
/// Apple's request looks for objects following a smooth parabolic path with a
/// known time stamp per frame — perfect for "ball hit by club and flying for a
/// fraction of a second". It runs on the ANE / GPU, so we can scan ~30+ frames
/// in well under a second. iOS 14+.
///
/// Usage:
///   let det = BallTrajectoryDetector()
///   let traj = await det.detect(in: videoURL, impactTimeSeconds: 2.13, windowSeconds: 1.5)
///
/// Returns nil when no plausible ball arc was found in the window.
final class BallTrajectoryDetector: @unchecked Sendable {
    private let trajectoryLength: Int
    private let objectMinSize: Float
    private let objectMaxSize: Float

    /// - Parameters:
    ///   - trajectoryLength: how many frames the request needs to confirm
    ///     a parabola. Smaller = lower latency, higher false-positive rate.
    ///     Apple recommends 5 minimum; 8 is a good golf compromise.
    ///   - objectMinSize / objectMaxSize: bounds in normalized image units for
    ///     what's considered a "ball-sized" object. Golf ball at 5–15m from a
    ///     phone camera is roughly 0.5%–3% of frame width.
    init(
        trajectoryLength: Int = 5,
        objectMinSize: Float = 0.002,
        objectMaxSize: Float = 0.10
    ) {
        self.trajectoryLength = trajectoryLength
        self.objectMinSize = objectMinSize
        self.objectMaxSize = objectMaxSize
    }

    /// Detect the highest-confidence parabolic trajectory in the given frame
    /// range. Returns nil if Vision found nothing.
    func detect(
        in videoURL: URL,
        impactFrameIndex: Int,
        startSeconds: Double,
        windowSeconds: Double,
        fps: Double,
        orientation: CGImagePropertyOrientation
    ) async -> BallTrajectory? {
        print("[BallTrajectory] start: impactFrame=\(impactFrameIndex) startSec=\(String(format: "%.3f", startSeconds)) win=\(windowSeconds)s fps=\(fps) orient=\(orientation.rawValue) "
              + "trajLen=\(trajectoryLength) minSize=\(objectMinSize) maxSize=\(objectMaxSize)")
        let asset = AVURLAsset(url: videoURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            print("[BallTrajectory] no video track on asset")
            return nil
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            print("[BallTrajectory] reader init failed: \(error.localizedDescription)")
            return nil
        }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        let endSeconds = startSeconds + windowSeconds
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, startSeconds), preferredTimescale: 600),
            duration: CMTime(seconds: windowSeconds, preferredTimescale: 600)
        )
        if reader.canAdd(output) { reader.add(output) }
        guard reader.startReading() else {
            print("[BallTrajectory] reader start failed: \(reader.error?.localizedDescription ?? "?")")
            return nil
        }

        // Build one persistent request; results accumulate across performs.
        var detected: [VNTrajectoryObservation] = []
        let request = VNDetectTrajectoriesRequest(
            frameAnalysisSpacing: .zero,
            trajectoryLength: trajectoryLength
        ) { req, _ in
            if let results = req.results as? [VNTrajectoryObservation] {
                detected.append(contentsOf: results)
            }
        }
        request.objectMinimumNormalizedRadius = objectMinSize
        request.objectMaximumNormalizedRadius = objectMaxSize

        let handler = VNSequenceRequestHandler()
        var processed = 0
        while let buf = output.copyNextSampleBuffer() {
            let ts = CMSampleBufferGetPresentationTimeStamp(buf)
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(buf) else { continue }
            do {
                try handler.perform([request],
                                    on: pixelBuffer,
                                    orientation: orientation)
                _ = ts
            } catch {
                // Vision can throw mid-stream if pixel format/orientation drifts;
                // skip the frame and keep going.
                continue
            }
            processed += 1
        }
        _ = endSeconds

        print("[BallTrajectory] window scanned: \(processed) frames, "
              + "\(detected.count) raw observations")
        guard !detected.isEmpty else {
            print("[BallTrajectory] no trajectory observed (try: bigger objectMaxSize, "
                  + "shorter trajectoryLength, or scan a wider window after Impact)")
            return nil
        }
        for (i, o) in detected.prefix(5).enumerated() {
            print("  obs[\(i)] conf=\(o.confidence) pts=\(o.detectedPoints.count) "
                  + "coeffs=(\(o.equationCoefficients.x),\(o.equationCoefficients.y),\(o.equationCoefficients.z))")
        }

        // Pick the highest-confidence observation that also has a usable number
        // of points (≥ 3 to be visually meaningful).
        let best = detected
            .filter { $0.detectedPoints.count >= 3 }
            .max(by: { $0.confidence < $1.confidence })
        guard let obs = best else {
            print("[BallTrajectory] all observations had <3 points; rejecting")
            return nil
        }

        // Vision returns points in lower-left origin normalized coords. Flip Y
        // so callers using top-left origin (UIKit / CGImage) can render directly.
        let pts: [BallTrajectory.Point] = obs.detectedPoints.enumerated().map { i, p in
            let secondsFromStart = Double(i) / max(fps, 1)
            return BallTrajectory.Point(
                x: Float(p.location.x),
                y: Float(1.0 - p.location.y),
                timeOffsetSeconds: secondsFromStart
            )
        }

        // Vision's equationCoefficients also follow lower-left origin.
        // y_ll = a*x² + b*x + c → y_tl = (1 - y_ll), so y_tl = -a*x² - b*x + (1 - c).
        let aLL = Float(obs.equationCoefficients.x)
        let bLL = Float(obs.equationCoefficients.y)
        let cLL = Float(obs.equationCoefficients.z)
        let aTL = -aLL
        let bTL = -bLL
        let cTL = 1.0 - cLL

        return BallTrajectory(
            a: aTL,
            b: bTL,
            c: cTL,
            points: pts,
            confidence: Float(obs.confidence),
            impactFrameIndex: impactFrameIndex,
            windowFrameCount: processed
        )
    }
}
