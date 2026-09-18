import AVFoundation
import Foundation

/// Keeps focus + metering pinned on the golfer using the live pose, instead of
/// whatever the camera's default scene metering picks. Two behaviours:
///
///   1. While the golfer is just standing there → continuously point focus +
///      exposure at the torso centroid (throttled).
///   2. At address (call `lock()`), freeze focus + exposure so the swing is
///      captured at constant brightness/focus — continuous AE "pumping" both
///      destabilises the pose model and looks bad on the recording. Call
///      `unlock()` after Finish to resume continuous metering.
///
/// All device mutation runs on the caller-provided session queue. The pose→
/// device-point mapping mirrors `VideoRecorder`'s orientation caveat and needs
/// on-device confirmation.
final class SubjectFocusController: @unchecked Sendable {
    private let device: AVCaptureDevice
    private let position: CameraPosition
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var lastPointAt: CFTimeInterval = 0
    private let minInterval: CFTimeInterval = 0.4
    private var locked = false

    // Auto-brighten: positive exposure bias driven by the measured face luma so
    // a dark/backlit face gets pulled up (background blows out — that's fine).
    private let maxBias: Float
    private var currentBias: Float = 0

    /// Far-restrict + smooth AF so the lens doesn't hunt on a distant golfer.
    init(device: AVCaptureDevice, position: CameraPosition, queue: DispatchQueue) {
        self.device = device
        self.position = position
        self.queue = queue
        self.maxBias = min(1.5, device.maxExposureTargetBias)   // cap at +1.5 EV (was +3: blew out backgrounds)
        configureBaseline()
    }

    /// Converge the camera's exposure bias so the face sits near `goal` luma.
    /// Only ever brightens (won't pull a fine face down); step-limited + dead-
    /// banded so it settles smoothly without pumping. Driven at LightingAdvisor's
    /// ~3 Hz with the face luma it just measured. Skipped while locked for a swing.
    func autoBrighten(faceLuma: Float) {
        lock.lock(); let isLocked = locked; lock.unlock()
        guard !isLocked else { return }
        // 0.40, not 0.50: pushing the face to mid-grey over-exposes the whole
        // frame outdoors (background blows out like a flashbang — device-test
        // feedback). 0.40 keeps the face readable without nuking the scene.
        let goal: Float = 0.40
        let err = goal - faceLuma                        // >0 ⇒ face too dark
        let desired = currentBias + err * 2.0            // gentler gain (was 3.0)
        let step = max(-0.25, min(0.25, desired - currentBias))
        let nb = max(0, min(currentBias + step, maxBias))
        guard abs(nb - currentBias) > 0.02 else { return }
        currentBias = nb
        queue.async { [self] in
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.setExposureTargetBias(nb, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    private func configureBaseline() {
        queue.async { [self] in
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .far   // golfer is several metres away
            }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
        }
    }

    /// Continuously bias focus + exposure toward the golfer's torso. Throttled.
    func update(pose: PoseFrame) {
        let now = CACurrentMediaTime()
        lock.lock()
        if locked || now - lastPointAt < minInterval { lock.unlock(); return }
        lastPointAt = now
        lock.unlock()

        guard let poi = subjectPOI(pose) else { return }
        queue.async { [self] in
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = poi
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = poi
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            }
            device.unlockForConfiguration()
        }
    }

    /// Freeze focus + exposure (call at address / swing start).
    func lockForSwing() {
        lock.lock(); locked = true; lock.unlock()
        queue.async { [self] in
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            device.unlockForConfiguration()
        }
    }

    /// Resume continuous metering (call after Finish).
    func unlock() {
        lock.lock(); locked = false; lock.unlock()
        queue.async { [self] in
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        }
    }

    // MARK: - pose → device point-of-interest

    /// Torso centroid (shoulders+hips) in device POI coords. POI is landscape
    /// sensor space (origin top-left, home button right). Back portrait maps
    /// portrait (px,py) → (py, 1-px).
    private func subjectPOI(_ pose: PoseFrame) -> CGPoint? {
        let idx = [5, 6, 11, 12]   // shoulders, hips
        var xs: [Float] = [], ys: [Float] = []
        for i in idx where i < pose.keypoints.count && pose.confidences[i] > 0.2 {
            xs.append(pose.keypoints[i].x); ys.append(pose.keypoints[i].y)
        }
        guard !xs.isEmpty else { return nil }
        let px = xs.reduce(0, +) / Float(xs.count)
        let py = ys.reduce(0, +) / Float(ys.count)
        let poi: CGPoint = position == .front
            ? CGPoint(x: CGFloat(py), y: CGFloat(px))
            : CGPoint(x: CGFloat(py), y: CGFloat(1 - px))
        return CGPoint(x: min(1, max(0, poi.x)), y: min(1, max(0, poi.y)))
    }
}
