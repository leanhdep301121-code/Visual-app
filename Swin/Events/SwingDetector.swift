import Foundation
import Observation

/// Always-on swing detector. Watches the live pose stream, triggers on:
///   1. Address held for ≥0.5s (hands near hip line, body still)
///   2. Backswing initiation (hands rising + velocity above threshold)
///   3. Swing finish (velocity below threshold for ≥1s after a plausible top)
/// Emits the buffered pose sequence for that swing on the main thread.
@Observable
final class SwingDetector: @unchecked Sendable {
    enum State: Sendable, Equatable {
        case waiting    // looking for stable address
        case armed      // address held, expecting backswing
        case swinging   // active swing in progress
    }

    private(set) var state: State = .waiting
    private(set) var swingCount: Int = 0

    /// Fired on the main thread when a complete swing is detected.
    var onSwingDetected: (([PoseFrame]) -> Void)?

    // ---- Tunables (normalized [0,1] image units; ~30 fps pose stream) ----
    private let addressFramesRequired = 15           // 0.5 s of held address before arming
    private let addressMaxHandFromHipY: Float = 0.30 // |hand_y − hip_y| / torso ≤ 0.3
    private let addressMaxSpeed: Float = 0.005       // hand speed over 5 frames
    private let backswingVelocity: Float = 0.012     // arms → swinging trigger
    private let backswingDirFrames = 3               // hand y must drop for k frames
    private let swingFinishMaxSpeed: Float = 0.005   // settled after impact
    private let swingFinishFrames = 30               // 1 s of low speed = done
    private let minSwingFrames = 30                  // <1 s is false trigger
    private let maxSwingFrames = 240                 // 8 s aborts (abandoned)
    private let leadInFrames = 5
    private let bufferCapacity = 600                 // 20 s @ 30 fps

    private let lock = NSLock()
    private var buffer: [PoseFrame] = []
    private var addressHeld = 0
    private var addressStartIdx: Int?
    private var swingStartIdx: Int?
    private var idleSinceActive = 0

    func reset() {
        lock.lock(); defer { lock.unlock() }
        clearLocked()
    }

    func ingest(_ pose: PoseFrame) {
        lock.lock(); defer { lock.unlock() }

        buffer.append(pose)
        if buffer.count > bufferCapacity {
            let drop = buffer.count - bufferCapacity
            buffer.removeFirst(drop)
            if let s = addressStartIdx { addressStartIdx = max(0, s - drop) }
            if let s = swingStartIdx   { swingStartIdx   = max(0, s - drop) }
        }
        guard buffer.count >= 6 else { return }

        let speed = handSpeed(over: 5)
        let now = buffer.count - 1

        switch state {
        case .waiting:
            if isInAddress(at: now, speed: speed) {
                addressHeld += 1
                if addressHeld >= addressFramesRequired {
                    addressStartIdx = max(0, now - addressHeld - leadInFrames)
                    publish(.armed)
                }
            } else {
                addressHeld = 0
            }

        case .armed:
            if speed > backswingVelocity, handsRising(over: backswingDirFrames) {
                swingStartIdx = addressStartIdx
                idleSinceActive = 0
                publish(.swinging)
            } else if !isInAddress(at: now, speed: speed) {
                // Lost address — drop back to waiting
                addressHeld = 0
                addressStartIdx = nil
                publish(.waiting)
            }

        case .swinging:
            guard let start = swingStartIdx else { abortSwing(); return }
            let length = now - start
            if length > maxSwingFrames {
                abortSwing()
                return
            }
            if speed < swingFinishMaxSpeed {
                idleSinceActive += 1
                if idleSinceActive >= swingFinishFrames {
                    if length >= minSwingFrames, isPlausibleSwing(start: start, end: now) {
                        let swing = Array(buffer[start...now])
                        let count = swingCount + 1
                        let cb = onSwingDetected
                        DispatchQueue.main.async {
                            self.swingCount = count
                            cb?(swing)
                        }
                    }
                    abortSwing()
                }
            } else {
                idleSinceActive = 0
            }
        }
    }

    // MARK: - State helpers

    private func publish(_ s: State) {
        DispatchQueue.main.async { self.state = s }
    }

    private func clearLocked() {
        buffer.removeAll(keepingCapacity: true)
        addressHeld = 0
        addressStartIdx = nil
        swingStartIdx = nil
        idleSinceActive = 0
        DispatchQueue.main.async { self.state = .waiting }
    }

    private func abortSwing() {
        addressHeld = 0
        addressStartIdx = nil
        swingStartIdx = nil
        idleSinceActive = 0
        publish(.waiting)
    }

    // MARK: - Pose math

    private func handMid(_ p: PoseFrame) -> SIMD2<Float> {
        let lw = p.keypoints[Joint.leftWrist]
        let rw = p.keypoints[Joint.rightWrist]
        return SIMD2<Float>((lw.x + rw.x) / 2, (lw.y + rw.y) / 2)
    }

    private func hipMid(_ p: PoseFrame) -> SIMD2<Float> {
        let lh = p.keypoints[Joint.leftHip]
        let rh = p.keypoints[Joint.rightHip]
        return SIMD2<Float>((lh.x + rh.x) / 2, (lh.y + rh.y) / 2)
    }

    private func torsoHeight(_ p: PoseFrame) -> Float {
        let h = hipMid(p)
        let lsY = p.keypoints[Joint.leftShoulder].y
        let rsY = p.keypoints[Joint.rightShoulder].y
        let lsX = p.keypoints[Joint.leftShoulder].x
        let rsX = p.keypoints[Joint.rightShoulder].x
        let shMid = SIMD2<Float>((lsX + rsX) / 2, (lsY + rsY) / 2)
        let dx = shMid.x - h.x
        let dy = shMid.y - h.y
        return max(0.05, sqrt(dx * dx + dy * dy))
    }

    private func handSpeed(over k: Int) -> Float {
        let n = buffer.count
        guard n >= k + 1 else { return 0 }
        let h0 = handMid(buffer[n - 1 - k])
        let h1 = handMid(buffer[n - 1])
        let dx = h1.x - h0.x
        let dy = h1.y - h0.y
        return sqrt(dx * dx + dy * dy) / Float(k)
    }

    private func handsRising(over k: Int) -> Bool {
        let n = buffer.count
        guard n >= k + 1 else { return false }
        let y0 = handMid(buffer[n - 1 - k]).y
        let y1 = handMid(buffer[n - 1]).y
        // upper-left origin: rising means decreasing y
        return y1 < y0 - 0.005
    }

    private func isInAddress(at idx: Int, speed: Float) -> Bool {
        let pose = buffer[idx]
        // Need decent confidence on key joints
        let needed = [Joint.leftWrist, Joint.rightWrist, Joint.leftHip, Joint.rightHip,
                      Joint.leftShoulder, Joint.rightShoulder]
        for j in needed where pose.confidences[j] < 0.4 { return false }
        let hand = handMid(pose)
        let hip = hipMid(pose)
        let torso = torsoHeight(pose)
        let dy = (hand.y - hip.y) / torso
        return abs(dy) < addressMaxHandFromHipY && speed < addressMaxSpeed
    }

    private func isPlausibleSwing(start: Int, end: Int) -> Bool {
        // Hands must rise above shoulder line at some point
        var minHandY = Float.infinity
        var shoulderYSum: Float = 0
        for i in start...end {
            let p = buffer[i]
            minHandY = min(minHandY, handMid(p).y)
            shoulderYSum += (p.keypoints[Joint.leftShoulder].y
                            + p.keypoints[Joint.rightShoulder].y) / 2
        }
        let shoulderAvg = shoulderYSum / Float(end - start + 1)
        return minHandY < shoulderAvg
    }
}
