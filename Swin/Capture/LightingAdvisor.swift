import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Observation

/// Detects bad lighting on the live frame and tells the user **which way to
/// move**. The judgment is the GOLFER'S FACE exposure, NOT the whole frame:
/// **a blown-out background is fine — the face is what must be exposed right.**
///
/// Robustness note: we build the luma grid in the SAME portrait orientation the
/// pose lives in (orient the buffer to `.right` first), then sample the face box
/// with pose coords DIRECTLY. No pose→sensor coordinate mapping → no orientation
/// bugs. The face box drawn on the preview and the box we meter are the same
/// rect, so "where it samples" is exactly what the user sees.
@Observable
final class LightingAdvisor: @unchecked Sendable {
    enum Condition: String, Sendable { case good, backlit, tooDark, tooBright }
    enum MoveHint: Sendable { case none, left, right, turnAround }

    struct Advice: Sendable, Equatable {
        let condition: Condition
        let hint: MoveHint
        let message: String
        /// Face metering box in PORTRAIT-normalized coords (top-left) + the luma
        /// it measured — for the UI to draw WHERE/WHAT we metered.
        var faceBox: CGRect? = nil
        var faceLuma: Float = 0
        var frameLuma: Float = 0
    }

    private(set) var advice: Advice?
    /// Fired on the main thread each time advice updates — used by
    /// CaptureController to drive auto-brighten from the measured face luma.
    var onResult: ((Advice) -> Void)?

    private let lock = NSLock()
    private var lastRunAt: CFTimeInterval = 0
    private let minInterval: CFTimeInterval = 0.33   // ~3 Hz

    private let cols = 32
    private let rows = 24
    private let ci = CIContext(options: [.useSoftwareRenderer: false])

    /// Face-exposure thresholds, [0,1] luma. Below `faceLo` = under-exposed;
    /// above `faceHi` = washed out. Tunable against labelled samples.
    private let faceLo: Float = 0.32
    private let faceHi: Float = 0.90
    /// Face counts as backlit when it's below this fraction of the frame's mean
    /// brightness (and a bright background exists). Tunable.
    private let backlitRatio: Float = 0.80

    func ingest(_ sampleBuffer: CMSampleBuffer, pose: PoseFrame?, position: CameraPosition) {
        let now = CACurrentMediaTime()
        lock.lock()
        if now - lastRunAt < minInterval { lock.unlock(); return }
        lastRunAt = now
        lock.unlock()

        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer),
              let grid = portraitLumaGrid(px, position: position) else { return }
        let result = analyze(grid: grid, pose: pose)
        DispatchQueue.main.async { [weak self] in
            self?.advice = result
            self?.onResult?(result)
        }
    }

    // MARK: - analysis

    private func analyze(grid: [[Float]], pose: PoseFrame?) -> Advice {
        let all = grid.flatMap { $0 }
        let frameMean = all.reduce(0, +) / Float(all.count)
        let brightFrac = Float(all.filter { $0 > 0.85 }.count) / Float(all.count)
        let bright = brightFrac > 0.12   // a meaningfully bright/blown background exists

        guard let pose, let faceBox = facePortraitRect(pose) else {
            if frameMean < 0.10 {
                return Advice(condition: .tooDark, hint: .none, message: String(localized: "光线太暗"))
            }
            return Advice(condition: .good, hint: .none, message: String(localized: "对准人再判光"))
        }

        let faceLuma = meanLuma(grid, in: faceBox)
        let cond: Condition, hint: MoveHint, msg: String

        // Backlight = the face is dark RELATIVE to a bright scene. Catches the
        // common case (face 0.38 against a blown-out window) that an absolute
        // threshold misses — and matches "背景过曝 OK, 人脸黑 = 逆光". A face
        // that tracks the scene brightness is fine even with a blown background.
        let backlit = bright && faceLuma < frameMean * backlitRatio

        if faceLuma < faceLo || backlit {
            if bright {
                hint = brightestSideHint(grid, faceCenterX: Float(faceBox.midX))
                cond = .backlit; msg = backlitMessage(hint)
            } else {
                cond = .tooDark; hint = .none; msg = String(localized: "人脸偏暗,挪亮处或正对光")
            }
        } else if faceLuma > faceHi {
            cond = .tooBright; hint = .none; msg = String(localized: "强光直射人脸,避开直射")
        } else {
            cond = .good; hint = .none; msg = String(localized: "人脸曝光合适")
        }
        return Advice(condition: cond, hint: hint, message: msg,
                      faceBox: faceBox, faceLuma: faceLuma, frameLuma: frameMean)
    }

    private func backlitMessage(_ hint: MoveHint) -> String {
        switch hint {
        case .left:  return String(localized: "逆光:强光在左,往右挪或把杆转到另一侧")
        case .right: return String(localized: "逆光:强光在右,往左挪或把杆转到另一侧")
        case .turnAround, .none: return String(localized: "逆光:太阳在身后,换个方向站位")
        }
    }

    /// Which side of the face the brightest region sits on, in PORTRAIT space.
    private func brightestSideHint(_ grid: [[Float]], faceCenterX: Float) -> MoveHint {
        var bestVal: Float = -1, bestCol = 0
        for r in 0..<rows { for c in 0..<cols where grid[r][c] > bestVal { bestVal = grid[r][c]; bestCol = c } }
        let brightX = (Float(bestCol) + 0.5) / Float(cols)
        if abs(brightX - faceCenterX) < 0.12 { return .turnAround }
        return brightX < faceCenterX ? .left : .right
    }

    /// Face box (nose/eyes/ears) in PORTRAIT-normalized coords. In profile / head
    /// down only some points show — that's fine, we box whatever's confident.
    private func facePortraitRect(_ pose: PoseFrame) -> CGRect? {
        let idx = [0, 1, 2, 3, 4]   // nose, eyes, ears
        var xs: [Float] = [], ys: [Float] = []
        for i in idx where i < pose.keypoints.count && pose.confidences[i] > 0.2 {
            xs.append(pose.keypoints[i].x); ys.append(pose.keypoints[i].y)
        }
        guard !xs.isEmpty else { return nil }   // no reliable face → stay inconclusive
        let px0 = max(0, xs.min()! - 0.04), px1 = min(1, xs.max()! + 0.04)
        let py0 = max(0, ys.min()! - 0.05), py1 = min(1, ys.max()! + 0.05)
        return CGRect(x: CGFloat(px0), y: CGFloat(py0), width: CGFloat(px1 - px0), height: CGFloat(py1 - py0))
    }

    // MARK: - luma (portrait space)

    private func meanLuma(_ grid: [[Float]], in rect: CGRect) -> Float {
        let c0 = max(0, Int(rect.minX * CGFloat(cols))), c1 = min(cols, Int(rect.maxX * CGFloat(cols)) + 1)
        let r0 = max(0, Int(rect.minY * CGFloat(rows))), r1 = min(rows, Int(rect.maxY * CGFloat(rows)) + 1)
        guard c1 > c0, r1 > r0 else { return grid.flatMap { $0 }.reduce(0, +) / Float(cols * rows) }
        var sum: Float = 0, n = 0
        for r in r0..<r1 { for c in c0..<c1 { sum += grid[r][c]; n += 1 } }
        return n > 0 ? sum / Float(n) : 0
    }

    /// Orient the buffer to PORTRAIT (same space as pose + preview), downscale to
    /// `rows × cols`, and read luma — origin top-left, so grid[0] is the top.
    private func portraitLumaGrid(_ px: CVPixelBuffer, position: CameraPosition) -> [[Float]]? {
        let orientation: CGImagePropertyOrientation = position == .front ? .leftMirrored : .right
        let oriented = CIImage(cvPixelBuffer: px).oriented(orientation)
        let ext = oriented.extent
        guard ext.width > 0, ext.height > 0 else { return nil }
        let scaled = oriented.transformed(by: CGAffineTransform(
            scaleX: CGFloat(cols) / ext.width, y: CGFloat(rows) / ext.height))
        var buf = [UInt8](repeating: 0, count: cols * rows * 4)
        ci.render(scaled, toBitmap: &buf, rowBytes: cols * 4,
                  bounds: CGRect(x: 0, y: 0, width: cols, height: rows),
                  format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var grid = [[Float]](repeating: [Float](repeating: 0, count: cols), count: rows)
        for r in 0..<rows {
            let src = rows - 1 - r   // CI bitmap origin is bottom-left → flip to top-left
            for c in 0..<cols {
                let o = (src * cols + c) * 4
                let rr = Float(buf[o]), g = Float(buf[o + 1]), b = Float(buf[o + 2])
                grid[r][c] = (0.299 * rr + 0.587 * g + 0.114 * b) / 255.0
            }
        }
        return grid
    }
}
