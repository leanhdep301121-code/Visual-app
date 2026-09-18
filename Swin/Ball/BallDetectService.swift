import AVFoundation
import CoreML
import Foundation
import Vision

/// YOLO ball detector (`GolfBallYOLO11n.mlpackage`, single class `golfball`) —
/// the fallback when Apple Vision's trajectory request finds nothing (it needs
/// a parabola sweeping across the frame; down-the-line shots barely move in
/// image space, but a per-frame detector still sees the ball while visible).
/// Produces the same `BallTrajectory` the report/overlay already consume.
final class BallDetectService {
    private let vnModel: VNCoreMLModel

    init() throws {
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        guard let url = Bundle.main.url(forResource: "GolfBallYOLO11n", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "GolfBallYOLO11n", withExtension: "mlpackage")
        else {
            throw NSError(domain: "Swin.BallDetect", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "GolfBallYOLO11n not bundled"])
        }
        let mlmodel = try MLModel(contentsOf: url, configuration: config)
        self.vnModel = try VNCoreMLModel(for: mlmodel)
    }

    /// Scan `windowSeconds` after `startSeconds`, track the moving ball, and
    /// build a `BallTrajectory` (≥ 4 moving points required).
    func detect(in url: URL,
                impactFrameIndex: Int,
                startSeconds: Double,
                windowSeconds: Double,
                orientation: CGImagePropertyOrientation,
                minConfidence: Float = 0.05) async -> BallTrajectory? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: windowSeconds, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        // Collect ALL candidate boxes per frame at LOW confidence. A driving
        // range is littered with REAL static balls that outscore the dim
        // flying one — single-best-box selection is exactly the wrong filter.
        // The flying ball is found by MOTION, not by score: it is the only
        // candidate whose position advances ballistically across frames.
        var frames: [(t: Double, boxes: [(x: Float, y: Float, conf: Float)])] = []
        var scanned = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            scanned += 1
            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            let request = VNCoreMLRequest(model: vnModel)
            request.imageCropAndScaleOption = .scaleFill
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation)
            try? handler.perform([request])
            guard let objs = request.results as? [VNRecognizedObjectObservation] else { continue }
            let boxes = objs.filter { $0.confidence >= minConfidence }
                .sorted { $0.confidence > $1.confidence }
                .prefix(12)
                .map { (Float($0.boundingBox.midX), Float(1 - $0.boundingBox.midY), $0.confidence) }
            if !boxes.isEmpty { frames.append((t, Array(boxes))) }
        }
        guard frames.count >= 4 else { return nil }

        // Greedy multi-hypothesis chaining: extend each chain with the nearest
        // candidate that moves a plausible per-frame step and keeps rising.
        struct Chain { var pts: [(x: Float, y: Float, conf: Float, t: Double)] }
        var chains: [Chain] = []
        for frame in frames {
            var extended = Set<Int>()
            for (ci, chain) in chains.enumerated() {
                guard let last = chain.pts.last, frame.t - last.t < 0.25 else { continue }
                var bestIdx = -1
                var bestD: Float = .greatestFiniteMagnitude
                for (bi, b) in frame.boxes.enumerated() {
                    let d = hypotf(b.x - last.x, b.y - last.y)
                    if d > 0.0015, d < 0.12, b.y < last.y + 0.006, d < bestD {
                        bestD = d; bestIdx = bi
                    }
                }
                if bestIdx >= 0 {
                    let b = frame.boxes[bestIdx]
                    chains[ci].pts.append((b.x, b.y, b.conf, frame.t))
                    extended.insert(bestIdx)
                }
            }
            // seed new chains from unclaimed boxes (cap total hypotheses)
            if chains.count < 24 {
                for (bi, b) in frame.boxes.enumerated() where !extended.contains(bi) {
                    chains.append(Chain(pts: [(b.x, b.y, b.conf, frame.t)]))
                }
            }
        }
        // The flying ball = longest rising chain with real climb.
        let ranked = chains
            .filter { $0.pts.count >= 4 }
            .filter { ($0.pts.first!.y - $0.pts.last!.y) > 0.035 }
            .sorted { $0.pts.count > $1.pts.count }
        guard let flight = ranked.first else { return nil }
        let pts = flight.pts
        _ = pts

        // Real flight sanity: distance from the first point must grow
        // (near-)monotonically and cover real ground — alternating false
        // positives (tee markers, sign letters) zigzag and fail this.
        let ox = pts[0].x, oy = pts[0].y
        var lastD: Float = 0
        var monotonic = true
        for p in pts {
            let d = hypotf(p.x - ox, p.y - oy)
            if d < lastD - 0.03 { monotonic = false; break }
            lastD = max(lastD, d)
        }
        guard monotonic, lastD > 0.04 else { return nil }

        // Quadratic fit y = a x² + b x + c for the overlay's coefficients.
        let (a, b, c) = Self.quadFit(pts.map { ($0.x, $0.y) })
        let t0 = pts[0].t
        var traj = BallTrajectory(
            a: a, b: b, c: c,
            points: pts.map { .init(x: $0.x, y: $0.y, timeOffsetSeconds: $0.t - t0) },
            confidence: pts.map(\.conf).reduce(0, +) / Float(pts.count),
            impactFrameIndex: impactFrameIndex,
            windowFrameCount: scanned)
        traj.firstObsMediaTime = t0
        return traj
    }

    /// Static ball at ADDRESS = launch origin. Runs the golf-ball YOLO on the
    /// frame at `atSeconds` and returns the ball box nearest `near` (the hands,
    /// from pose) — the ball the club is about to strike, out of the many
    /// static range balls. Normalized top-left [0,1]. The ball doesn't move
    /// from address to impact, so this is a rock-solid launch anchor when there
    /// is no club track.
    func staticBall(in url: URL, atSeconds: Double, near: CGPoint,
                    orientation: CGImagePropertyOrientation,
                    windowSeconds: Double = 0.6,
                    minConfidence: Float = 0.10) async -> CGPoint? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        // Scan a WINDOW (not one frame) — the address frame guess can land in
        // the backswing where the hands are up and the dim tee ball is missed.
        // The ball is static from address to impact, so any frame in the window
        // sees it; take the detection nearest `near` (the flight-extrapolated
        // launch), which snaps onto the real mat ball.
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, atSeconds - windowSeconds / 2),
                                                     preferredTimescale: 600),
                                       duration: CMTime(seconds: windowSeconds, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        func dist(_ p: CGPoint) -> CGFloat {
            let dx = p.x - near.x, dy = p.y - near.y
            return (dx * dx + dy * dy).squareRoot()
        }
        var best: CGPoint? = nil
        var bestD: CGFloat = .greatestFiniteMagnitude
        var idx = 0
        while let sample = output.copyNextSampleBuffer() {
            defer { idx += 1 }
            if idx % 2 != 0 { continue }                 // every other frame
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let request = VNCoreMLRequest(model: vnModel)
            request.imageCropAndScaleOption = .scaleFill
            try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation).perform([request])
            guard let objs = request.results as? [VNRecognizedObjectObservation] else { continue }
            for o in objs where o.confidence >= minConfidence {
                let p = CGPoint(x: o.boundingBox.midX, y: 1 - o.boundingBox.midY)  // top-left norm
                let d = dist(p)
                if d < bestD { bestD = d; best = p }
            }
        }
        reader.cancelReading()
        // Only accept if it's reasonably near the expected launch (else it's a
        // random range ball, not the struck one).
        return bestD < 0.18 ? best : nil
    }

    /// Least-squares quadratic through (x, y) points (normal equations, 3×3).
    private static func quadFit(_ p: [(Float, Float)]) -> (Float, Float, Float) {
        var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        var t0 = 0.0, t1 = 0.0, t2 = 0.0
        for (xf, yf) in p {
            let x = Double(xf), y = Double(yf)
            let x2 = x * x
            s0 += 1; s1 += x; s2 += x2; s3 += x2 * x; s4 += x2 * x2
            t0 += y; t1 += x * y; t2 += x2 * y
        }
        // Solve [s4 s3 s2; s3 s2 s1; s2 s1 s0] [a b c]ᵀ = [t2 t1 t0]ᵀ (Cramer).
        func det3(_ m: [Double]) -> Double {
            m[0]*(m[4]*m[8]-m[5]*m[7]) - m[1]*(m[3]*m[8]-m[5]*m[6]) + m[2]*(m[3]*m[7]-m[4]*m[6])
        }
        let M  = [s4, s3, s2, s3, s2, s1, s2, s1, s0]
        let d  = det3(M)
        guard abs(d) > 1e-12 else { return (0, 0, 0) }
        let da = det3([t2, s3, s2, t1, s2, s1, t0, s1, s0])
        let db = det3([s4, t2, s2, s3, t1, s1, s2, t0, s0])
        let dc = det3([s4, s3, t2, s3, s2, t1, s2, s1, t0])
        return (Float(da / d), Float(db / d), Float(dc / d))
    }
}
