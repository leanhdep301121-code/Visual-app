import AVFoundation
import CoreML
import CoreMedia
import Foundation

/// Single-image camera calibration (GeoCalib, ECCV 2024) — recovers the
/// ground-plane pitch (horizon) + focal for IMPORTED clips that carry NO IMU
/// gravity. Runs ONCE per clip on one frame; ~0.3–0.8 s on the ANE.
///
/// The 830-line Levenberg-Marquardt optimizer stays OFF-device: the network
/// emits a per-pixel `latitude` field (angle from the horizon), and the horizon
/// is simply its zero-crossing — validated to match the full LM (0.428 vs
/// 0.40 true on the night/rear-view clip where the hand-rolled horizon kept
/// failing). Focal comes from the field's slope.
///
/// Model I/O: input `image` (1,3,576,320) RGB ÷255 (portrait); outputs
/// `latitude` (1,1,576,320) and `up` (1,2,576,320).
final class GeoCalibService {
    private let model: MLModel
    private let W = 320
    private let H = 576

    /// `horizonY`: normalized [0,1] top-left row of the horizon in the ORIGINAL
    /// frame. `pitchRad`: ground-plane pitch (camera down positive). `focalPx`:
    /// focal in original-frame pixels.
    struct Result { let horizonY: Float; let pitchRad: Float; let focalPx: Float }

    init() throws {
        let config = MLModelConfiguration()
        // NOT .all — the int8-quantized net fails ANE compilation
        // (MILCompilerForANE ANECCompile FAILED), and the failed-compile +
        // fallback burned 39 s. cpuAndGPU skips the ANE path entirely (~1–2 s).
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .cpuAndGPU
        #endif
        guard let url = Bundle.main.url(forResource: "GeoCalibNet", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "GeoCalibNet", withExtension: "mlpackage")
        else {
            throw NSError(domain: "Swin.GeoCalib", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "GeoCalibNet not bundled"])
        }
        self.model = try MLModel(contentsOf: url, configuration: config)
    }

    /// Calibrate from the frame at `atSeconds`. `videoSize` = display-oriented
    /// size; the horizon/focal are returned in that frame's pixel space.
    func calibrate(in url: URL, atSeconds: Double, videoSize: CGSize,
                   orientation: CGImagePropertyOrientation) async -> Result? {
        guard let f = await frameRGB(url: url, atSeconds: atSeconds, orientation: orientation)
        else { return nil }
        let rgb = f.rgb
        guard let arr = try? MLMultiArray(shape: [1, 3, NSNumber(value: H), NSNumber(value: W)],
                                          dataType: .float32) else { return nil }
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
        let plane = H * W
        for p in 0..<plane {
            ptr[p]             = rgb[p * 3 + 0] / 255      // R
            ptr[plane + p]     = rgb[p * 3 + 1] / 255      // G
            ptr[2 * plane + p] = rgb[p * 3 + 2] / 255      // B
        }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["image": arr]),
              let out = try? await model.prediction(from: input),
              let lat = out.featureValue(for: "latitude")?.multiArrayValue,
              lat.shape.count == 4 else { return nil }

        // latitude(1,1,H,W): tanh output ≈ latitude/(π/2). Read the centre
        // column, find the zero-crossing row (= horizon) with sub-pixel interp.
        let s = lat.strides.map { $0.intValue }
        let sY = s[2], sX = s[3]
        let xc = W / 2
        @inline(__always) func at(_ y: Int) -> Float { readF(lat, y * sY + xc * sX) }

        var horizonRow: Float = -1
        for y in 0..<(H - 1) {
            let a = at(y), b = at(y + 1)
            if a == 0 { horizonRow = Float(y); break }
            if a * b < 0 { horizonRow = Float(y) + a / (a - b); break }   // a→0 crossing
        }
        guard horizonRow >= 0 else { return nil }

        // The model saw a CENTRE CROP of the display-oriented frame, `f.cropH`
        // pixels tall starting at `f.cropY`. Map the horizon row back to the
        // full frame, and measure the focal against the crop's vertical field of
        // view — not the full height, which the model never saw.
        let origH = Float(videoSize.height)
        let horizonY = (f.cropY + horizonRow / Float(H) * f.cropH) / origH
        let cy = origH / 2

        // Focal from the latitude slope: latitude(y) ≈ atan((y − y_h)/f_field).
        // Near a reference row, tan(lat) ≈ (y − y_h)/f_field → f_field. Scale to
        // original pixels. Sample 25 % below the horizon for a stable slope.
        let refY = min(H - 2, Int(horizonRow) + H / 4)
        let latRef = at(refY) * (.pi / 2)                  // tanh → radians
        let dyField = Float(refY) - horizonRow
        var focalPx: Float = origH * 0.72                  // fallback ~26 mm-equiv
        if abs(latRef) > 0.02, abs(tan(latRef)) > 1e-3 {
            let fField = abs(dyField / tan(latRef))
            focalPx = fField * (f.cropH / Float(H))
        }

        let pitch = atan((cy - horizonY * origH) / focalPx)
        return Result(horizonY: horizonY, pitchRad: pitch, focalPx: focalPx)
    }

    // MARK: - helpers

    /// Read a float from an MLMultiArray at flat index, dispatching on dtype
    /// (ANE returns Float16).
    private func readF(_ a: MLMultiArray, _ i: Int) -> Float {
        switch a.dataType {
        case .float16:
            return Float(a.dataPointer.bindMemory(to: Float16.self, capacity: a.count)[i])
        case .float32:
            return a.dataPointer.bindMemory(to: Float.self, capacity: a.count)[i]
        case .double:
            return Float(a.dataPointer.bindMemory(to: Double.self, capacity: a.count)[i])
        default: return 0
        }
    }

    /// Decode the frame at `atSeconds`, stretch to W×H, return RGB (HWC, 0…255,
    /// top-left) via a direct BGRA pixel read (no CoreImage flip).
    /// One frame rotated to display orientation and centre-cropped to the
    /// model's aspect. `cropY`/`cropH` locate that crop in the display frame so
    /// the horizon row and focal can be mapped back.
    private struct Frame { let rgb: [Float]; let cropY: Float; let cropH: Float }

    private func frameRGB(url: URL, atSeconds: Double,
                          orientation: CGImagePropertyOrientation) async -> Frame? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, atSeconds), preferredTimescale: 600),
                                       duration: CMTime(seconds: 0.25, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading(),
              let sample = output.copyNextSampleBuffer(),
              let px = CMSampleBufferGetImageBuffer(sample) else { return nil }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px) else { return nil }
        let sw = CVPixelBufferGetWidth(px), sh = CVPixelBufferGetHeight(px)
        let bpr = CVPixelBufferGetBytesPerRow(px)
        let src = base.assumingMemoryBound(to: UInt8.self)   // BGRA, top-left
        // Display-space dimensions: a quarter turn swaps them.
        let quarterTurn = orientation == .right || orientation == .left
            || orientation == .rightMirrored || orientation == .leftMirrored
        let dw = quarterTurn ? sh : sw
        let dh = quarterTurn ? sw : sh
        // Centre-crop the DISPLAY frame to the model's 320:576, then stretch.
        // Feeding the whole frame instead distorts it — harmless for portrait
        // (1080×1920 = 0.5625 vs the model's 0.5555) which is why this never
        // surfaced, but a 1264×720 landscape clip gets squeezed 3.95× wide and
        // stretched 0.8× tall. GeoCalib then reported focal 302 (FOV 128°, no
        // phone has that) → anchorZ 1.1 m → the whole scale shrank ~2.2×.
        // Cropping keeps the vertical field of view, which is what the focal
        // step measures against.
        let want = Float(W) / Float(H)                       // 0.5555
        let cropW: Int, cropH: Int, cropX: Int, cropY: Int
        if Float(dw) / Float(dh) > want {                    // too wide → trim sides
            cropW = Int((Float(dh) * want).rounded()); cropH = dh
            cropX = (dw - cropW) / 2; cropY = 0
        } else {                                             // too tall → trim top/bottom
            cropW = dw; cropH = Int((Float(dw) / want).rounded())
            cropX = 0; cropY = (dh - cropH) / 2
        }
        var out = [Float](repeating: 0, count: W * H * 3)
        for ty in 0..<H {
            let orow = ty * W * 3
            let yd = cropY + min(cropH - 1, ty * cropH / H)   // pixel in DISPLAY space
            for tx in 0..<W {
                let xd = cropX + min(cropW - 1, tx * cropW / W)
                // display → raw, inverting the EXIF transform (same table as
                // TrackNetBallDetector.resizeToRGB).
                let sx: Int, sy: Int
                switch orientation {
                case .up:            sx = xd;            sy = yd            // 1
                case .upMirrored:    sx = sw - 1 - xd;   sy = yd            // 2
                case .down:          sx = sw - 1 - xd;   sy = sh - 1 - yd   // 3
                case .downMirrored:  sx = xd;            sy = sh - 1 - yd   // 4
                case .leftMirrored:  sx = yd;            sy = xd            // 5
                case .right:         sx = yd;            sy = sh - 1 - xd   // 6
                case .rightMirrored: sx = sw - 1 - yd;   sy = sh - 1 - xd   // 7
                case .left:          sx = sw - 1 - yd;   sy = xd            // 8
                @unknown default:    sx = xd;            sy = yd
                }
                let sp = min(sh - 1, max(0, sy)) * bpr + min(sw - 1, max(0, sx)) * 4
                out[orow + tx * 3 + 0] = Float(src[sp + 2])  // R
                out[orow + tx * 3 + 1] = Float(src[sp + 1])  // G
                out[orow + tx * 3 + 2] = Float(src[sp + 0])  // B
            }
        }
        reader.cancelReading()
        return Frame(rgb: out, cropY: Float(cropY), cropH: Float(cropH))
    }
}
