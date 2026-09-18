import Accelerate
import AVFoundation
import CoreGraphics
import Foundation

/// Motion-based ball recovery — the third rung of the ball ladder (Vision
/// trajectories → YOLO → this). Ports the offline night-range pipeline that
/// was validated on real footage (tools/ball_trace_offline.py): frame-diff on
/// the luma plane + approximate top-hat (diff − box-blur) inside a corridor
/// above the address ball, then a rising-chain gate. Catches the dim fast
/// ball that detectors miss at night (per ball-tracer pipeline doc §S2).
final class MotionBallDetector {

    /// Launch-witness candidates: strong movers NEAR THE TEE in the first
    /// frames around impact, time-sorted. Even when the full chain drowns in
    /// floodlight shimmer (night), these pin the launch TIME — the most
    /// degenerate dimension of the monocular fit. The CALLER must veto the
    /// clubhead (bright, sweeps the corridor right at impact — it produced a
    /// witness 1 frame早 and 0.06 right of the ball) using the club track.
    private(set) var earlyTeeCandidates: [(x: Float, y: Float, t: Double)] = []

    /// `corridorCenter` — normalized [0,1] position of the ball at address
    /// (from the club track's address clubhead); nil = frame-center band.
    func detect(in url: URL,
                impactFrameIndex: Int,
                startSeconds: Double,
                windowSeconds: Double,
                orientation: CGImagePropertyOrientation,
                corridorCenter: CGPoint?) async -> BallTrajectory? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: windowSeconds, preferredTimescale: 600))
        // Decode with the track's rotation APPLIED (video composition) so
        // frames arrive display-upright and corridor math needs no manual
        // sensor-space mapping — the hand-rolled .left/.right mapping guessed
        // wrong on -90° clips and the corridor landed on the wrong side of
        // the frame (motion pass returned 0 pts on footage the offline
        // pipeline handled). BGRA out; we take the green plane as luma.
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.videoComposition = AVVideoComposition(propertiesOf: asset)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var prev: [UInt8]? = nil
        var prevW = 0, prevH = 0
        var raw: [(x: Float, y: Float, t: Double, s: Float)] = []

        while let sample = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let rowBytes = CVPixelBufferGetBytesPerRow(pb)
            var luma = [UInt8](repeating: 0, count: w * h)
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let p = base.assumingMemoryBound(to: UInt8.self)
                for r in 0..<h {
                    let row = p.advanced(by: r * rowBytes)
                    for c in 0..<w { luma[r * w + c] = row[c * 4 + 1] }   // BGRA → G
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)

            if let p = prev, prevW == w, prevH == h {
                for hit in Self.peaks(cur: luma, prev: p, w: w, h: h,
                                      corridorCenter: corridorCenter) {
                    raw.append((hit.x, hit.y, t, hit.s))
                }
            }
            prev = luma; prevW = w; prevH = h
        }
        // Witness candidates: near-tee movers in the first 6 distinct frames.
        earlyTeeCandidates = []
        if let tee = corridorCenter {
            let firstFrames = Set(Array(Set(raw.map(\.t))).sorted().prefix(6))
            earlyTeeCandidates = raw
                .filter { firstFrames.contains($0.t) }
                .filter { hypotf($0.x - Float(tee.x), $0.y - Float(tee.y)) < 0.12 }
                .sorted { $0.t < $1.t }
                .map { (x: $0.x, y: $0.y, t: $0.t) }
            print("[motion] tee candidates: \(earlyTeeCandidates.count)")
        }
        print("[motion] raw candidates: \(raw.count)")
        guard raw.count >= 5 else { return nil }

        // Multi-hypothesis rising chains — same lesson as the YOLO selector:
        // a single per-frame peak loses the dim ball to floodlight shimmer
        // (night range: a whole band of lights out-tophats the ball on most
        // frames). Seed a chain at EVERY candidate, greedily extend with the
        // physics gates, keep the best rise×length chain.
        raw.sort { $0.t < $1.t }
        var frames: [Double] = []
        var byFrame: [Double: [(x: Float, y: Float, t: Double, s: Float)]] = [:]
        for p in raw {
            if byFrame[p.t] == nil { frames.append(p.t); byFrame[p.t] = [] }
            byFrame[p.t]!.append(p)
        }
        var best: [(x: Float, y: Float, t: Double, s: Float)] = []
        for (fi, f0) in frames.enumerated() {
            for seed in byFrame[f0]! {
                var chain = [seed]
                var misses = 0
                for f in frames.dropFirst(fi + 1) {
                    guard misses <= 2 else { break }
                    let last = chain.last!
                    // best gated candidate this frame (smallest step)
                    let next = byFrame[f]!
                        .filter { c in
                            let step = hypotf(c.x - last.x, c.y - last.y)
                            return step > 0.003 && step < 0.12
                                && c.y < last.y + 0.006          // keeps rising
                        }
                        .min { hypotf($0.x - last.x, $0.y - last.y)
                             < hypotf($1.x - last.x, $1.y - last.y) }
                    if let next { chain.append(next); misses = 0 } else { misses += 1 }
                }
                let rise = chain.first!.y - chain.last!.y
                // Straightness: net displacement / path length. Floodlight
                // shimmer forms long chains that zig-zag in x with tiny net
                // motion (measured 0.15); a real ball path is ~0.9.
                var pathLen: Float = 0
                for j in 1..<chain.count {
                    pathLen += hypotf(chain[j].x - chain[j-1].x, chain[j].y - chain[j-1].y)
                }
                let net = hypotf(chain.last!.x - chain.first!.x, chain.last!.y - chain.first!.y)
                let straight = pathLen > 0 ? net / pathLen : 0
                let bestRise = best.isEmpty ? 0 : best.first!.y - best.last!.y
                if chain.count >= 5, rise > 0.08, straight > 0.55,
                   chain.count + Int(rise * 20) > best.count + Int(bestRise * 20) {
                    best = chain
                }
            }
        }
        var pts = best
        // Club-contamination split (offline lesson, swing_002): the follow-
        // through clubhead sweeps the corridor for a few frames at ~6× the
        // ball's screen speed. Trim any fast prefix; keep the slow ball tail.
        while pts.count >= 2 {
            let step = hypotf(pts[1].x - pts[0].x, pts[1].y - pts[0].y)
            if step > 0.03 { pts.removeFirst() } else { break }
        }
        print("[motion] best chain: \(pts.count) pts (raw \(raw.count))")
        guard pts.count >= 5 else { return nil }
        let rise = pts.first!.y - pts.last!.y
        guard rise > 0.08 else { return nil }                     // real climb

        let (a, b, c) = Self.quadFit(pts.map { ($0.x, $0.y) })
        let t0 = pts[0].t
        var traj = BallTrajectory(
            a: a, b: b, c: c,
            points: pts.map { .init(x: $0.x, y: $0.y, timeOffsetSeconds: $0.t - t0) },
            confidence: 0.5,                                      // heuristic source
            impactFrameIndex: impactFrameIndex,
            windowFrameCount: raw.count)
        traj.firstObsMediaTime = t0
        return traj
    }

    /// Top-K small bright movers in the corridor: |cur−prev| minus its 9×9
    /// box blur ≈ top-hat; local peaks above threshold, 15 px NMS. K > 1 is
    /// load-bearing at night — floodlight shimmer out-tophats the dim ball
    /// on most frames, so the ball is often the 2nd-4th peak.
    private static func peaks(cur: [UInt8], prev: [UInt8], w: Int, h: Int,
                              corridorCenter: CGPoint?, k: Int = 6) -> [(x: Float, y: Float, s: Float)] {
        let n = w * h
        var diff = [Float](repeating: 0, count: n)
        var curF = [Float](repeating: 0, count: n)
        var prevF = [Float](repeating: 0, count: n)
        vDSP.convertElements(of: cur, to: &curF)
        vDSP.convertElements(of: prev, to: &prevF)
        vDSP.subtract(curF, prevF, result: &diff)
        vDSP.absolute(diff, result: &diff)

        // 9×9 box blur via two 1-D passes (separable): horizontal conv, then
        // transpose → conv → transpose back. A single 1-D conv over the
        // flattened buffer (the previous code) is NOT a 2-D blur — top-hat
        // values came out wrong and nothing passed the threshold on footage
        // the offline pipeline handled fine.
        let k: Int = 9
        let kernel = [Float](repeating: 1.0 / Float(k), count: k)
        func hconv(_ src: [Float]) -> [Float] {
            var dst = [Float](repeating: 0, count: src.count)
            src.withUnsafeBufferPointer { s in
                dst.withUnsafeMutableBufferPointer { d in
                    vDSP_conv(s.baseAddress!, 1, kernel, 1, d.baseAddress!, 1,
                              vDSP_Length(src.count - k), vDSP_Length(k))
                }
            }
            return dst
        }
        var blur = hconv(diff)
        var tr = [Float](repeating: 0, count: n)
        vDSP_mtrans(blur, 1, &tr, 1, vDSP_Length(w), vDSP_Length(h))
        tr = hconv(tr)
        vDSP_mtrans(tr, 1, &blur, 1, vDSP_Length(h), vDSP_Length(w))
        var tophat = [Float](repeating: 0, count: n)
        vDSP.subtract(diff, blur, result: &tophat)

        // Corridor check — frames arrive display-upright (rotation applied at
        // decode), so normalized coords are direct.
        let cx = corridorCenter?.x ?? 0.5
        let bandHalf: CGFloat = 0.14
        func inCorridor(_ xs: Int, _ ys: Int) -> Bool {
            let xp = CGFloat(xs) / CGFloat(w)
            let yp = CGFloat(ys) / CGFloat(h)
            guard abs(xp - cx) < bandHalf else { return false }
            return yp > 0.18 && yp < (corridorCenter?.y ?? 0.9) + 0.05
        }

        var out: [(x: Float, y: Float, s: Float)] = []
        let nmsR = 15
        for _ in 0..<k {
            var best: (idx: Int, v: Float) = (-1, 22)             // threshold ≈ offline 25
            var i = 0
            while i < n {
                let v = tophat[i]
                if v > best.v {
                    let xs = i % w, ys = i / w
                    if inCorridor(xs, ys) { best = (i, v) }
                }
                i += 1
            }
            guard best.idx >= 0 else { break }
            let xs = best.idx % w, ys = best.idx / w
            out.append((Float(CGFloat(xs) / CGFloat(w)), Float(CGFloat(ys) / CGFloat(h)), best.v))
            // NMS: zero a disk around the accepted peak.
            for dy in -nmsR...nmsR {
                let yy = ys + dy
                guard yy >= 0, yy < h else { continue }
                for dx in -nmsR...nmsR where dx * dx + dy * dy <= nmsR * nmsR {
                    let xx = xs + dx
                    guard xx >= 0, xx < w else { continue }
                    tophat[yy * w + xx] = 0
                }
            }
        }
        return out
    }

    private static func quadFit(_ p: [(Float, Float)]) -> (Float, Float, Float) {
        var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        var t0 = 0.0, t1 = 0.0, t2 = 0.0
        for (xf, yf) in p {
            let x = Double(xf), y = Double(yf)
            let x2 = x * x
            s0 += 1; s1 += x; s2 += x2; s3 += x2 * x; s4 += x2 * x2
            t0 += y; t1 += x * y; t2 += x2 * y
        }
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
