import AVFoundation
import CoreImage
import CoreML
import CoreMedia
import Foundation

/// TrackNetV3 (U-Net heatmap) flying-ball detector — on-device port of the
/// tennis-domain TrackNet that, on real golf footage, tracked the POST-IMPACT
/// ball where Vision/YOLO lost it (validated offline on the side-view clips).
///
/// ⚠️ Input contract — must match training EXACTLY or the heatmap is garbage:
///   `frames` (1, 27, 288, 512), float, normalized ÷255, **RGB** order,
///   channel layout = `[median_R,G,B, f0_R,G,B, f1…, f7_R,G,B]`
///   (background/median prepended, then 8 frames). WIDTH 512 × HEIGHT 288.
/// Output `heatmap` (1, 8, 288, 512): one heatmap per frame in the window;
/// per-channel arg-max → ball pixel (scale ×origW/512, ×origH/288).
/// Sliding-window step = `seqLen` (8).
///
/// Runs as a POST-IMPACT BURST (not live): decode the window, build a median
/// background, slide 8-frame windows — ~1 s on the ANE. Returns the same
/// `BallTrajectory` the report/overlay already consume (normalized top-left).
final class TrackNetBallDetector {
    private let model: MLModel
    private let W = 512
    private let H = 288
    private let seqLen = 8
    private let inChannels = 27         // 3 (median) + 8×3 (frames)

    init() throws {
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        guard let url = Bundle.main.url(forResource: "TrackNet", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "TrackNet", withExtension: "mlpackage")
        else {
            throw NSError(domain: "Swin.TrackNet", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "TrackNet.mlpackage not bundled"])
        }
        self.model = try MLModel(contentsOf: url, configuration: config)
    }

    // MARK: - public

    /// Detect the post-impact flight track in `[startSeconds, +windowSeconds]`.
    /// Points are normalized top-left [0,1]; `timeOffsetSeconds` is seconds
    /// since impact. Returns nil when the window has < seqLen frames or no
    /// heatmap peak clears the visibility threshold.
    /// - Parameter clubTrack: clubhead samples from ClubDetectYOLO11n, when
    ///   available. Used ONLY to veto chains that are tracking the club rather
    ///   than the ball — the badminton-weights heatmap fires hard on the
    ///   follow-through clubhead, which forms a long smooth arc that outscores
    ///   the real ball on (displacement, length). Sparse is fine: the veto only
    ///   looks at points that have a clubhead sample nearby in time.
    func detect(in url: URL,
                impactFrameIndex: Int,
                impactSeconds: Double,
                startSeconds: Double,
                windowSeconds: Double,
                orientation: CGImagePropertyOrientation,
                clubTrack: [(x: Float, y: Float, t: Double)]? = nil) async -> BallTrajectory? {
        let tStart = CFAbsoluteTimeGetCurrent()
        guard let decoded = await decodeWindow(url: url, start: startSeconds, duration: windowSeconds,
                                              orientation: orientation)
        else { return nil }
        let frames = decoded.frames                 // each: [Float] H*W*3, HWC, 0…255, RGB
        let times = decoded.times
        guard frames.count >= seqLen else { return nil }
        let tDecoded = CFAbsoluteTimeGetCurrent()

        // Median background from the detection window (subsampled). Decoding
        // the WHOLE clip for a cleaner median doubled the on-device latency for
        // a marginal parity gain — the window median is good enough and free
        // (these frames are already decoded).
        let median = computeMedian(frames)
        let tMedian = CFAbsoluteTimeGetCurrent()

        // Candidates are stored PER FRAME and overwritten, never appended: the
        // tail window overlaps the previous one (see `starts` below), so an
        // appending collector would keep two independent blob sets for the
        // overlapped frames. Those duplicates can't extend a chain (dt == 0 is
        // rejected) — they seed parallel phantom chains that then compete for
        // the (displacement, length) win. Last window to cover a frame wins,
        // matching tracknet_diag.py's `per_frame[s + f] = blobs(heat[f])`.
        var perFrame = [[(fi: Int, x: Float, y: Float, t: Double, peak: Float)]](
            repeating: [], count: frames.count)
        // Slide non-overlapping 8-frame windows; snap the last to the tail so
        // no frames are dropped (matches predict.py sliding_step = seq_len).
        var starts: [Int] = Array(stride(from: 0, through: frames.count - seqLen, by: seqLen))
        if let last = starts.last, last + seqLen < frames.count { starts.append(frames.count - seqLen) }

        var tInfer = 0.0, tDecodeHeat = 0.0
        for s in starts {
            guard let input = try? buildInput(median: median, frames: frames, start: s) else { continue }
            let a = CFAbsoluteTimeGetCurrent()
            guard let out = try? await model.prediction(from: input),
                  let heat = out.featureValue(for: "heatmap")?.multiArrayValue
            else { continue }
            let b = CFAbsoluteTimeGetCurrent(); tInfer += b - a
            // Keep ALL blobs per frame (not just largest-area): the club head,
            // a static tee ball, and edge artefacts are extra candidates the
            // ballistic chain will drop. Largest-area alone picked the club head
            // on some frames (validated on the night clips).
            for f in 0..<seqLen {
                perFrame[s + f] = ballBlobs(heat, channel: f).map {
                    (fi: s + f, x: $0.x, y: $0.y, t: times[s + f], peak: $0.value)
                }
            }
            tDecodeHeat += CFAbsoluteTimeGetCurrent() - b
        }
        let allCands = perFrame.flatMap { $0 }
        print(String(format: "[TrackNet] timing: decode %.2fs median %.2fs infer %.2fs heatdecode %.2fs (%d frames, %d windows)",
                     tDecoded - tStart, tMedian - tDecoded, tInfer, tDecodeHeat, frames.count, starts.count))
        guard allCands.count >= 3 else { return nil }

        // Ballistic multi-hypothesis chain: link candidates into chains with a
        // plausible per-frame step, keep the longest that actually MOVES
        // (net displacement > threshold) → the flying ball. The club head is an
        // off-parabola singleton / short chain and is dropped; a static tee ball
        // forms a near-zero-displacement chain and is rejected.
        guard let flight = chainFlight(allCands, clubTrack: clubTrack), flight.count >= 3 else { return nil }
        print("[TrackNet] flight \(flight.count)/\(allCands.count): " + flight.map {
            String(format: "(%.3f,%.3f@%.2fs)", $0.x, $0.y, $0.t)
        }.joined(separator: " "))

        let t0 = flight.first!.t
        let pts = flight.map {
            BallTrajectory.Point(x: $0.x, y: $0.y, timeOffsetSeconds: $0.t - impactSeconds)
        }
        // Fit y = a x² + b x + c in normalized coords for the struct header
        // (overlays use `points`; the quadratic is a coarse summary only).
        let (a, b, c) = fitQuadratic(pts)
        return BallTrajectory(a: a, b: b, c: c, points: pts,
                              confidence: flight.map(\.peak).reduce(0, +) / Float(flight.count),
                              impactFrameIndex: impactFrameIndex,
                              windowFrameCount: frames.count,
                              predictedPoints: nil,
                              firstObsMediaTime: t0)
    }

    // MARK: - decode (rotated to display orientation, resized to W×H, RGB HWC 0…255)

    private struct Decoded { let frames: [[Float]]; let times: [Double]; let size: CGSize }

    /// Decode `[start, start+duration]`, every `everyN`-th frame. Uses the raw
    /// track output (NO video composition) + a direct pixel-buffer read →
    /// top-left origin, BGRA, exactly like OpenCV in the offline Python
    /// pipeline. (The old CoreImage `render(toBitmap:)` path flipped Y — CIImage
    /// is bottom-left origin — which drifted every detection off the Python
    /// result. new2 has no rotation, so native == display here.)
    private func decodeWindow(url: URL, start: Double, duration: Double,
                              orientation: CGImagePropertyOrientation,
                              everyN: Int = 1) async -> Decoded? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: duration, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var frames: [[Float]] = []
        var times: [Double] = []
        var size: CGSize = .zero
        var idx = 0
        while let sample = output.copyNextSampleBuffer(), let px = CMSampleBufferGetImageBuffer(sample) {
            defer { idx += 1 }
            if idx % everyN != 0 { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if size == .zero {
                let raw = CGSize(width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))
                let quarterTurn = orientation == .right || orientation == .left
                    || orientation == .rightMirrored || orientation == .leftMirrored
                size = quarterTurn ? CGSize(width: raw.height, height: raw.width) : raw
            }
            if let rgb = resizeToRGB(px, orientation: orientation) { frames.append(rgb); times.append(t) }
        }
        reader.cancelReading()
        return frames.isEmpty ? nil : Decoded(frames: frames, times: times, size: size)
    }

    /// Direct BGRA read + nearest-neighbour stretch to W×H → RGB (HWC, 0…255),
    /// top-left origin. The W×H grid is a stretch of the DISPLAY-oriented frame,
    /// not of the raw buffer: the rotation is folded into the sample index here
    /// rather than applied to the output coordinates afterwards.
    ///
    /// Why it must happen here and not on the coords: normalized blob centres
    /// feed pose-derived geometry (the ankle ground line, `videoSize`, the
    /// overlay canvas) that all live in display space, so raw-buffer coords are
    /// simply a different frame of reference — a portrait clip's ball reads as
    /// a point in the sky. Rotating the coords afterwards would fix the frame
    /// of reference but still show TrackNet a landscape image, while the
    /// validated offline pipeline (cv2 auto-applies the rotation metadata) feeds
    /// it a PORTRAIT frame squeezed into 512×288. The model must see the same
    /// picture as the run we validated against, so rotate the pixels.
    private func resizeToRGB(_ px: CVPixelBuffer,
                             orientation: CGImagePropertyOrientation) -> [Float]? {
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px) else { return nil }
        let sw = CVPixelBufferGetWidth(px), sh = CVPixelBufferGetHeight(px)
        let bpr = CVPixelBufferGetBytesPerRow(px)
        let src = base.assumingMemoryBound(to: UInt8.self)   // BGRA, top-left, row-major
        // Display-space dimensions: a quarter turn swaps them.
        let quarterTurn = orientation == .right || orientation == .left
            || orientation == .rightMirrored || orientation == .leftMirrored
        let dw = quarterTurn ? sh : sw
        let dh = quarterTurn ? sw : sh
        var out = [Float](repeating: 0, count: W * H * 3)
        for ty in 0..<H {
            let yd = min(dh - 1, (ty * dh) / H)      // pixel in DISPLAY space
            let orow = ty * W * 3
            for tx in 0..<W {
                let xd = min(dw - 1, (tx * dw) / W)
                // display → raw, inverting the EXIF transform. All 8 cases are
                // spelled out: the mirrored ones (front camera) share the
                // dimension swap with their unmirrored twins, so falling them
                // through to the identity branch would pair rotated dimensions
                // with unrotated sampling and quietly smear the frame.
                let sx: Int, sy: Int
                switch orientation {
                case .up:            sx = xd;            sy = yd            // 1
                case .upMirrored:    sx = sw - 1 - xd;   sy = yd            // 2
                case .down:          sx = sw - 1 - xd;   sy = sh - 1 - yd   // 3: rot 180°
                case .downMirrored:  sx = xd;            sy = sh - 1 - yd   // 4
                case .leftMirrored:  sx = yd;            sy = xd            // 5: transpose
                case .right:         sx = yd;            sy = sh - 1 - xd   // 6: rot 90° CW
                case .rightMirrored: sx = sw - 1 - yd;   sy = sh - 1 - xd   // 7: transverse
                case .left:          sx = sw - 1 - yd;   sy = xd            // 8: rot 90° CCW
                @unknown default:    sx = xd;            sy = yd
                }
                let sp = min(sh - 1, max(0, sy)) * bpr + min(sw - 1, max(0, sx)) * 4
                out[orow + tx * 3 + 0] = Float(src[sp + 2])  // R (BGRA: R at +2)
                out[orow + tx * 3 + 1] = Float(src[sp + 1])  // G
                out[orow + tx * 3 + 2] = Float(src[sp + 0])  // B
            }
        }
        return out
    }

    // MARK: - median background (per pixel-channel)

    private func computeMedian(_ frames: [[Float]]) -> [Float] {
        // Subsample to ≤9 frames (static background → sparse median is clean).
        // Flatten into one contiguous buffer and work through unsafe pointers:
        // the array-of-arrays + bounds checks made this 5.8 s in a DEBUG build
        // (Release is ~20× faster, but keep it snappy for on-device testing).
        let step = max(1, frames.count / 9)
        let idxs = Array(Swift.stride(from: 0, to: frames.count, by: step))
        let k = idxs.count
        let n = W * H * 3
        let mid = k / 2
        var flat = [Float](repeating: 0, count: k * n)   // [k][n]
        flat.withUnsafeMutableBufferPointer { fp in
            for j in 0..<k {
                frames[idxs[j]].withUnsafeBufferPointer { sp in
                    let base = j * n
                    for i in 0..<n { fp[base + i] = sp[i] }
                }
            }
        }
        var median = [Float](repeating: 0, count: n)
        flat.withUnsafeBufferPointer { fp in
            median.withUnsafeMutableBufferPointer { mp in
                var col = [Float](repeating: 0, count: k)
                col.withUnsafeMutableBufferPointer { cp in
                    for i in 0..<n {
                        for j in 0..<k { cp[j] = fp[j * n + i] }
                        // insertion sort — k ≤ 9, faster than Array.sort here
                        for a in 1..<k {
                            let v = cp[a]; var b = a - 1
                            while b >= 0 && cp[b] > v { cp[b + 1] = cp[b]; b -= 1 }
                            cp[b + 1] = v
                        }
                        mp[i] = cp[mid]
                    }
                }
            }
        }
        return median
    }

    // MARK: - input tensor  (1, 27, 288, 512) = [median, f0…f7], /255, RGB

    private func buildInput(median: [Float], frames: [[Float]], start: Int) throws -> MLDictionaryFeatureProvider {
        let arr = try MLMultiArray(shape: [1, NSNumber(value: inChannels),
                                           NSNumber(value: H), NSNumber(value: W)],
                                   dataType: .float32)
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
        // channels 0…2: median (HWC → CHW)
        writePlanes(into: ptr, base: 0, hwc: median)
        // channels 3…26: 8 frames
        for f in 0..<seqLen {
            writePlanes(into: ptr, base: (1 + f) * 3, hwc: frames[start + f])
        }
        return try MLDictionaryFeatureProvider(dictionary: ["frames": arr])
    }

    /// Scatter an HWC (0…255 RGB) image into three CHW planes at `base`, ÷255.
    private func writePlanes(into ptr: UnsafeMutablePointer<Float>, base: Int, hwc: [Float]) {
        let plane = H * W
        for p in 0..<plane {
            ptr[(base + 0) * plane + p] = hwc[p * 3 + 0] / 255
            ptr[(base + 1) * plane + p] = hwc[p * 3 + 1] / 255
            ptr[(base + 2) * plane + p] = hwc[p * 3 + 2] / 255
        }
    }

    // MARK: - heatmap decode

    /// Ball location from one heatmap channel — MATCHES the Python decode
    /// (`predict.py`: `y>0.5` → `cv2.findContours` → largest-**area** bbox →
    /// its center). NOT arg-max — a bigger dim region would out-vote the true
    /// peak by area, so arg-max drifts off the Python result. Returns nil when
    /// no pixel clears 0.5 (Python's "not visible").
    /// ⚠️ CoreML on the ANE returns Float16 — dispatch on `heat.dataType` or
    /// the wrong element size over-reads and EXC_BAD_ACCESSes.
    private func ballBlobs(_ heat: MLMultiArray, channel c: Int) -> [(x: Float, y: Float, value: Float)] {
        guard heat.shape.count == 4 else { return [] }
        let strides = heat.strides.map { $0.intValue }
        let sC = strides[1], sY = strides[2], sX = strides[3]
        let cBase = c * sC
        let ptr16: UnsafeMutablePointer<Float16>? =
            heat.dataType == .float16 ? heat.dataPointer.bindMemory(to: Float16.self, capacity: heat.count) : nil
        let ptr32: UnsafeMutablePointer<Float>? =
            heat.dataType == .float32 ? heat.dataPointer.bindMemory(to: Float.self, capacity: heat.count) : nil
        let ptr64: UnsafeMutablePointer<Double>? =
            heat.dataType == .double ? heat.dataPointer.bindMemory(to: Double.self, capacity: heat.count) : nil
        guard ptr16 != nil || ptr32 != nil || ptr64 != nil else { return [] }
        // Read the channel into a dense H×W grid.
        var grid = [Float](repeating: 0, count: H * W)
        for y in 0..<H {
            let row = cBase + y * sY
            for x in 0..<W {
                let i = row + x * sX
                grid[y * W + x] = ptr16 != nil ? Float(ptr16![i]) : (ptr32 != nil ? ptr32![i] : Float(ptr64![i]))
            }
        }
        // Threshold 0.5 → connected components (8-conn); return ALL blob centers
        // (normalized) + peak. The ballistic chain downstream picks the flying
        // one; a per-frame largest-area pick grabbed the club head on some frames.
        var visited = [Bool](repeating: false, count: H * W)
        var stack: [Int] = []
        var out: [(x: Float, y: Float, value: Float)] = []
        for start in 0..<(H * W) where !visited[start] && grid[start] > 0.5 {
            stack.removeAll(keepingCapacity: true)
            stack.append(start); visited[start] = true
            var minX = W, maxX = 0, minY = H, maxY = 0, peak: Float = 0
            while let p = stack.popLast() {
                let px = p % W, py = p / W
                minX = min(minX, px); maxX = max(maxX, px)
                minY = min(minY, py); maxY = max(maxY, py)
                peak = max(peak, grid[p])
                for dy in -1...1 {
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        let nx = px + dx, ny = py + dy
                        guard nx >= 0, nx < W, ny >= 0, ny < H else { continue }
                        let np = ny * W + nx
                        if !visited[np] && grid[np] > 0.5 { visited[np] = true; stack.append(np) }
                    }
                }
            }
            let w = maxX - minX + 1, h = maxY - minY + 1
            let cx = (Float(minX) + Float(w) / 2) / Float(W)
            let cy = (Float(minY) + Float(h) / 2) / Float(H)
            out.append((x: cx, y: cy, value: peak))
        }
        return out
    }

    /// Ballistic multi-hypothesis chain (mirrors the offline `chain_ball`): link
    /// per-frame candidates into chains with a plausible per-frame image step
    /// (< 0.14 normalized / frame), then keep the chain that both persists AND
    /// MOVES (net displacement > 0.12) — the flying ball. Club-head/static-tee/
    /// edge candidates are singletons or near-zero-displacement chains → dropped.
    private func chainFlight(_ cands: [(fi: Int, x: Float, y: Float, t: Double, peak: Float)],
                             clubTrack: [(x: Float, y: Float, t: Double)]? = nil)
        -> [(x: Float, y: Float, t: Double, peak: Float)]? {
        struct Chain { var pts: [(fi: Int, x: Float, y: Float, t: Double, peak: Float)] }
        var chains: [Chain] = []
        let byFrame = Dictionary(grouping: cands, by: { $0.fi })
        for fi in byFrame.keys.sorted() {
            for c in byFrame[fi]! {
                var bestIdx = -1
                var bestStep: Float = .greatestFiniteMagnitude
                for (ci, ch) in chains.enumerated() {
                    guard let last = ch.pts.last else { continue }
                    let dt = fi - last.fi
                    if dt <= 0 || dt > 5 { continue }
                    let step = hypotf(c.x - last.x, c.y - last.y) / Float(dt)
                    if step < 0.14, step < bestStep { bestStep = step; bestIdx = ci }
                }
                if bestIdx >= 0 { chains[bestIdx].pts.append((fi, c.x, c.y, c.t, c.peak)) }
                else { chains.append(Chain(pts: [(fi, c.x, c.y, c.t, c.peak)])) }
            }
        }
        func disp(_ ch: Chain) -> Float {
            guard let f = ch.pts.first, let l = ch.pts.last else { return 0 }
            return hypotf(l.x - f.x, l.y - f.y)
        }
        /// True when this chain is riding the clubhead, not the ball. Scored as
        /// a MAJORITY, not "any point": ball and club are genuinely co-located
        /// for a frame or two around impact, so a single overlap must not veto
        /// the real flight. Points with no clubhead sample within 60 ms don't
        /// vote either way — the detector is sparse by design (see ClubTrack).
        func ridesClub(_ ch: Chain) -> Bool {
            guard let club = clubTrack, !club.isEmpty else { return false }
            var judged = 0, onClub = 0
            for p in ch.pts {
                guard let c = club.min(by: { abs($0.t - p.t) < abs($1.t - p.t) }),
                      abs(c.t - p.t) < 0.06 else { continue }
                judged += 1
                if hypotf(p.x - c.x, p.y - c.y) < 0.05 { onClub += 1 }
            }
            return judged >= 3 && onClub * 2 > judged
        }
        let good = chains.filter { $0.pts.count >= 3 && disp($0) > 0.12 && !ridesClub($0) }
        guard let best = good.max(by: { (disp($0), $0.pts.count) < (disp($1), $1.pts.count) })
        else { return nil }
        return best.pts.map { (x: $0.x, y: $0.y, t: $0.t, peak: $0.peak) }
    }

    // MARK: - coarse quadratic (struct header only)

    private func fitQuadratic(_ pts: [BallTrajectory.Point]) -> (Float, Float, Float) {
        guard pts.count >= 3 else { return (0, 0, pts.first?.y ?? 0) }
        // Least-squares y = a x² + b x + c via normal equations (3×3).
        var Sx = 0.0, Sx2 = 0.0, Sx3 = 0.0, Sx4 = 0.0, Sy = 0.0, Sxy = 0.0, Sx2y = 0.0
        let n = Double(pts.count)
        for p in pts {
            let x = Double(p.x), y = Double(p.y)
            let x2 = x * x
            Sx += x; Sx2 += x2; Sx3 += x2 * x; Sx4 += x2 * x2
            Sy += y; Sxy += x * y; Sx2y += x2 * y
        }
        // Solve [Sx4 Sx3 Sx2; Sx3 Sx2 Sx; Sx2 Sx n] · [a b c]ᵀ = [Sx2y Sxy Sy]ᵀ
        let m = [[Sx4, Sx3, Sx2], [Sx3, Sx2, Sx], [Sx2, Sx, n]]
        let v = [Sx2y, Sxy, Sy]
        guard let s = solve3(m, v) else { return (0, 0, Float(Sy / n)) }
        return (Float(s[0]), Float(s[1]), Float(s[2]))
    }

    private func solve3(_ A0: [[Double]], _ b0: [Double]) -> [Double]? {
        var A = A0, b = b0
        for col in 0..<3 {
            var piv = col
            for r in (col + 1)..<3 where abs(A[r][col]) > abs(A[piv][col]) { piv = r }
            guard abs(A[piv][col]) > 1e-12 else { return nil }
            A.swapAt(col, piv); b.swapAt(col, piv)
            for r in (col + 1)..<3 {
                let f = A[r][col] / A[col][col]
                for k in col..<3 { A[r][k] -= f * A[col][k] }
                b[r] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: 3)
        for r in stride(from: 2, through: 0, by: -1) {
            var s = b[r]
            for k in (r + 1)..<3 { s -= A[r][k] * x[k] }
            x[r] = s / A[r][r]
        }
        return x
    }
}
