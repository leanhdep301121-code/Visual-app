import Foundation

protocol EventDetector: Sendable {
    func detect(_ poses: [PoseFrame]) -> SwingEvents
}

/// Faithful port of `swing_analyze/events.py:detect_events` from the PC pipeline.
/// Operates on normalized image coords (upper-left origin), so PC pixel-space
/// constants are scaled to normalized equivalents.
///
/// **T1 swap-in note**: when `PoseTCN.mlpackage` is available, add a
/// `PoseTCNEventDetector: EventDetector` next to this file and inject it via
/// `SwingRecorder.eventDetector`. The protocol contract is the only public surface.
struct HeuristicEventDetector: EventDetector {
    func detect(_ poses: [PoseFrame]) -> SwingEvents {
        let T = poses.count
        guard T >= 10 else { return .undetected }

        let handedness = detectHandedness(poses)

        let handsX = poses.map { ($0.keypoints[Joint.leftWrist].x + $0.keypoints[Joint.rightWrist].x) / 2 }
        let handsY = poses.map { ($0.keypoints[Joint.leftWrist].y + $0.keypoints[Joint.rightWrist].y) / 2 }
        let hipsY = poses.map { ($0.keypoints[Joint.leftHip].y + $0.keypoints[Joint.rightHip].y) / 2 }
        let shouldersY = poses.map { ($0.keypoints[Joint.leftShoulder].y + $0.keypoints[Joint.rightShoulder].y) / 2 }

        var speed = [Float](repeating: 0, count: T)
        for i in 1..<T {
            let dx = handsX[i] - handsX[i - 1]
            let dy = handsY[i] - handsY[i - 1]
            speed[i] = (dx * dx + dy * dy).squareRoot()
        }

        let hipBaseline = median(hipsY)
        let shoulderBaseline = median(shouldersY)

        // Top: min hands_y in first 75%
        let searchEnd = max(Int(Float(T) * 0.75), 5)
        var topIdx = 0
        var topY = handsY[0]
        for i in 0..<searchEnd where handsY[i] < topY {
            topY = handsY[i]; topIdx = i
        }

        // Impact: max speed after top, refined to first frame hands return near hip baseline
        var impactIdx = topIdx
        var maxSpeed: Float = -1
        for i in topIdx..<T where speed[i] > maxSpeed {
            maxSpeed = speed[i]; impactIdx = i
        }
        let refineEnd = min(topIdx + Int(Float(T) * 0.4), T)
        for i in topIdx..<refineEnd where handsY[i] >= hipBaseline {
            impactIdx = max(impactIdx, i)
            break
        }
        impactIdx = min(impactIdx, T - 1)

        // Address: first stable low-position frame before top
        let win = max(3, Int(Float(T) * 0.02))
        var motion = [Float](repeating: 0, count: topIdx + 1)
        for i in 0...topIdx {
            let lo = max(0, i - win)
            var sum: Float = 0
            for j in lo...i { sum += speed[j] }
            motion[i] = sum / Float(i - lo + 1)
        }
        let motionMax = motion.max() ?? 0
        let motionThresh = motionMax * 0.15
        // PC: hip_baseline * 0.15 + 20px (in 1920 height) ≈ hip_baseline * 0.15 + 0.0104
        let nearHipThresh = hipBaseline * 0.15 + 0.012
        var addressIdx = 0
        for i in 0...topIdx {
            if motion[i] < motionThresh && abs(handsY[i] - hipBaseline) < nearHipThresh {
                addressIdx = i; break
            }
        }

        // Finish: last frame with hands above shoulder baseline after impact
        var finishIdx = T - 1
        if impactIdx + 1 < T {
            var lastHigh = -1
            for i in (impactIdx + 1)..<T where handsY[i] < shoulderBaseline {
                lastHigh = i
            }
            if lastHigh >= 0 { finishIdx = lastHigh }
        }

        // Toe-up: first hands above hip during backswing
        var toeUpIdx = min(addressIdx + 1, topIdx)
        for i in addressIdx...topIdx where handsY[i] < hipBaseline {
            toeUpIdx = i; break
        }

        // Mid-backswing: first hands at/above shoulder during BS
        var midBsIdx = (addressIdx + topIdx) / 2
        for i in addressIdx...topIdx where handsY[i] < shoulderBaseline {
            midBsIdx = i; break
        }

        // Mid-downswing: first hands at/below shoulder during DS
        var midDsIdx = (topIdx + impactIdx) / 2
        if topIdx <= impactIdx {
            for i in topIdx...impactIdx where handsY[i] > shoulderBaseline {
                midDsIdx = i; break
            }
        }

        // Mid-follow-through: first hands above shoulder during FT, skip post-impact buffer
        let ftBuffer = max(2, Int(Float(finishIdx - impactIdx) * 0.15))
        let ftStart = min(impactIdx + ftBuffer, finishIdx)
        var midFtIdx = (impactIdx + finishIdx) / 2
        if ftStart < finishIdx {
            for i in ftStart...finishIdx where handsY[i] < shoulderBaseline {
                midFtIdx = i; break
            }
        }

        var frames = [addressIdx, toeUpIdx, midBsIdx, topIdx, midDsIdx, impactIdx, midFtIdx, finishIdx]
        for i in 1..<frames.count where frames[i] < frames[i - 1] {
            frames[i] = frames[i - 1]
        }
        frames = frames.map { min($0, T - 1) }
        return SwingEvents(frames: frames, handedness: handedness)
    }

    private func detectHandedness(_ poses: [PoseFrame]) -> Handedness {
        let n = max(3, poses.count / 10)
        var lwx: Float = 0, rwx: Float = 0
        for i in 0..<n {
            lwx += poses[i].keypoints[Joint.leftWrist].x
            rwx += poses[i].keypoints[Joint.rightWrist].x
        }
        return (lwx / Float(n) < rwx / Float(n)) ? .right : .left
    }

    private func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        return n.isMultiple(of: 2) ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2 : sorted[n / 2]
    }
}
