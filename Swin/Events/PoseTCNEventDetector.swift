import CoreMedia
import CoreML
import Foundation

/// Pose-TCN event detector for whole-clip analysis (upload / onboarding path).
///
/// Uses the SAME proven v3.1 inference engine as the live tracker
/// (`PoseTCNEventDetectorCore`) — migrated off the older PoseTCN_v2 so the
/// upload path and the live path run the identical, latest model. v3.1 input is
/// 102-dim per frame (51 pos+conf + 51 frame-to-frame Δ); all that feature work
/// lives in the Core. Here we only orchestrate sliding windows over an
/// arbitrary-length clip and decode the 8 events.
///
/// Output: per-frame softmax over 9 classes [Address, Toe-up, Mid-bs, Top,
/// Mid-ds, Impact, Mid-fl, Finish, no-event]. For clips > 64 frames we run
/// sliding windows (stride 32) and average per-frame softmax, then decode each
/// event as its per-class argmax across the clip and enforce monotonic order.
struct PoseTCNEventDetector: EventDetector {
    private let core: PoseTCNEventDetectorCore
    private let windowSize: Int = 64
    private let stride: Int = 32

    init() throws {
        self.core = try PoseTCNEventDetectorCore()
    }

    func detect(_ poses: [PoseFrame]) -> SwingEvents {
        guard poses.count >= 16 else { return .undetected }
        // PoseTCN is trained on UNIFORM 30 fps. A dropped/irregular live buffer
        // stretches the 64-frame window past 2.13 s and drifts every event
        // (~0.5 s off). Resample onto a 30 fps grid by timestamp first so the
        // model gets the input contract it expects. Already-uniform input (the
        // upload / re-analysis path reads every video frame) is left unchanged.
        let uniform = Self.resampleUniform30(poses)
        let n = uniform.count
        guard n >= 16 else { return .undetected }

        let probs  = slidingWindowInference(poses: uniform, n: n)     // (n, 9), softmaxed
        var uframes = decodeEvents(probs: probs, n: n)
        for i in 1..<uframes.count where uframes[i] < uframes[i - 1] {
            uframes[i] = uframes[i - 1]
        }
        // Map uniform-grid event indices back to the ORIGINAL pose array by TIME,
        // so SwingEvents.frames index the poses actually stored/displayed (the
        // overlay already maps time↔frame by timestamp).
        let frames = uframes.map { idx -> Int in
            guard idx >= 0, idx < uniform.count else { return -1 }
            return Self.nearestIndex(byTime: CMTimeGetSeconds(uniform[idx].timestamp), in: poses)
        }
        return SwingEvents(frames: frames, handedness: detectHandedness(poses))
    }

    // MARK: - uniform-30fps resample (restore PoseTCN's input contract)

    /// Resample a pose sequence onto a uniform `fps` grid by timestamp, linearly
    /// interpolating keypoints + confidences. No-op when the input is already
    /// ~uniform at that rate (upload path). Fixes PoseTCN event drift caused by
    /// dropped/irregular live-capture frames.
    static func resampleUniform30(_ poses: [PoseFrame], fps: Double = 30) -> [PoseFrame] {
        guard poses.count >= 2 else { return poses }
        let t0 = CMTimeGetSeconds(poses.first!.timestamp)
        let t1 = CMTimeGetSeconds(poses.last!.timestamp)
        let span = t1 - t0
        guard span > 0.05 else { return poses }
        let count = max(2, Int((span * fps).rounded()) + 1)
        // Already ~uniform at this rate → don't interpolate needlessly.
        if abs(Double(poses.count) - Double(count)) <= 1 { return poses }
        var out: [PoseFrame] = []; out.reserveCapacity(count)
        var j = 0
        let jc = poses.count
        for i in 0..<count {
            let t = t0 + Double(i) / fps
            while j + 1 < jc && CMTimeGetSeconds(poses[j + 1].timestamp) < t { j += 1 }
            let a = poses[j]
            let b = (j + 1 < jc) ? poses[j + 1] : poses[j]
            let ta = CMTimeGetSeconds(a.timestamp), tb = CMTimeGetSeconds(b.timestamp)
            let f = Float(tb > ta ? (t - ta) / (tb - ta) : 0)
            out.append(Self.lerp(a, b, f, timeSeconds: t))
        }
        return out
    }

    private static func lerp(_ a: PoseFrame, _ b: PoseFrame, _ f: Float, timeSeconds t: Double) -> PoseFrame {
        let n = a.keypoints.count
        var kp = [SIMD2<Float>](repeating: .zero, count: n)
        var cf = [Float](repeating: 0, count: n)
        for k in 0..<n {
            kp[k] = a.keypoints[k] + (b.keypoints[k] - a.keypoints[k]) * f
            cf[k] = a.confidences[k] + (b.confidences[k] - a.confidences[k]) * f
        }
        return PoseFrame(timestamp: CMTime(seconds: t, preferredTimescale: 600),
                         keypoints: kp, confidences: cf,
                         isoNormalized: a.isoNormalized, imageAspect: a.imageAspect)
    }

    private static func nearestIndex(byTime t: Double, in poses: [PoseFrame]) -> Int {
        var best = 0
        var bestD = Double.infinity
        for (i, p) in poses.enumerated() {
            let d = abs(CMTimeGetSeconds(p.timestamp) - t)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    // MARK: - sliding window inference (delegates per-window work to the v3.1 Core)

    private func slidingWindowInference(poses: [PoseFrame], n: Int) -> [[Float]] {
        var probsAcc = Array(repeating: [Float](repeating: 0, count: 9), count: n)
        var counts   = [Int](repeating: 0, count: n)

        let starts: [Int]
        if n <= windowSize {
            starts = [0]
        } else {
            var s: [Int] = []
            var i = 0
            while i + windowSize <= n {
                s.append(i)
                i += stride
            }
            if let last = s.last, last + windowSize < n {
                s.append(n - windowSize)
            }
            starts = s
        }

        for start in starts {
            let end = min(start + windowSize, n)
            let window = Array(poses[start..<end])
            // Frame before the window so v3.1's velocity at window-start matches
            // PC's whole-video pre-computation (nil for the first window → vel0 = 0).
            let previous = start > 0 ? poses[start - 1] : nil
            let winProbs = core.inferWindow(window, previousPose: previous)   // (end-start, 9)
            for (t, p) in winProbs.enumerated() {
                let frameIdx = start + t
                if frameIdx >= n { break }
                for c in 0..<9 { probsAcc[frameIdx][c] += p[c] }
                counts[frameIdx] += 1
            }
        }
        for i in 0..<n where counts[i] > 0 {
            for c in 0..<9 { probsAcc[i][c] /= Float(counts[i]) }
        }
        return probsAcc
    }

    // MARK: - decode

    private func decodeEvents(probs: [[Float]], n: Int) -> [Int] {
        var frames = [Int](repeating: -1, count: 8)
        for ev in 0..<8 {
            var bestProb: Float = -1
            var bestFrame = -1
            for t in 0..<n where probs[t][ev] > bestProb {
                bestProb = probs[t][ev]
                bestFrame = t
            }
            frames[ev] = bestFrame
        }
        return frames
    }

    private func detectHandedness(_ poses: [PoseFrame]) -> Handedness {
        let nPick = max(3, poses.count / 10)
        var lwx: Float = 0
        var rwx: Float = 0
        for i in 0..<nPick {
            lwx += poses[i].keypoints[Joint.leftWrist].x
            rwx += poses[i].keypoints[Joint.rightWrist].x
        }
        return (lwx / Float(nPick) < rwx / Float(nPick)) ? .right : .left
    }
}
