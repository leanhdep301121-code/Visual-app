import CoreML
import Foundation
import Observation

/// Real-time swing detection — v3 phase-progression argmax state machine.
///
/// Validated on PC against a 22-second 2-swing video (see
/// scripts/realtime_swing_sim_v3.py + docs/realtime_sim_v3_multi/).
/// Detected both swings with plausible 8-event timing.
///
/// State machine (one PoseTCN inference per `STRIDE_INF` new frames):
///   IDLE:
///     `K_ADDR` consecutive frames with argmax over 8 event classes == Address
///     AND that class's prob >= FLOOR → ADDRESS_HELD (note swing_start)
///   ADDRESS_HELD:
///     argmax goes to Toe-up / Mid-bs above FLOOR → SWINGING
///     argmax falls below FLOOR for `ADDR_LOST_FRAMES` → IDLE
///   SWINGING:
///     Track 'seen_tail' = once argmax has been Mid-fl or Finish above FLOOR
///     Once seen_tail, watch for K_QUIET consecutive frames with prob < QUIET_THR
///       → emit, run full-clip decode on [swing_start - 5 .. now + 5]
///     Hard timeout MAX_SWING_FRAMES → abort to IDLE
///   COOLDOWN: K_COOL frames, → IDLE.
@Observable
final class LiveSwingTracker: @unchecked Sendable {
    enum State: Sendable, Equatable {
        case idle
        case addressHeld
        case swinging
        case cooldown
    }

    private(set) var state: State = .idle
    /// Best frame so far for each of the 8 events (-1 if not yet detected
    /// for the currently-tracked swing). Indices in absolute buffer space.
    private(set) var liveEventFrames: [Int] = Array(repeating: -1, count: 8)
    private(set) var swingCount: Int = 0
    /// Current argmax over the 8 event classes for the most recent inference,
    /// only set when its prob >= FLOOR. -1 otherwise. Useful for HUD.
    private(set) var currentArgmax: Int = -1
    /// Number of distinct mid-swing phases (Toe-up..Mid-fl) observed during
    /// the current swing. 0 when in idle. Published for the debug panel so
    /// user can see swing-confidence accumulating live.
    private(set) var currentPhasesSeen: Int = 0
    /// Raw 8-class probabilities from the most recent inference. All zeros
    /// until first inference fires. Surfaced to RecordView's debug panel so
    /// the user can see per-event signal strength in real time.
    private(set) var currentProbs: [Float] = Array(repeating: 0, count: 8)
    /// Last N (t, probs) tuples for sparkline display. Frame index is
    /// absolute buffer position. Ring buffer trimmed to keep ~3 sec of history.
    private(set) var recentProbsHistory: [(t: Int, probs: [Float])] = []
    private let probsHistoryCapacity = 120  // ~4 sec @ 30 fps
    /// Optional file URL to append a CSV of per-inference probs. nil = no log.
    /// Set via `startProbsLogging()` so user can debug from disk later.
    private(set) var probsLogURL: URL?
    /// Human-readable result of the most recent emit attempt: "EMIT #n …" on a
    /// real swing, or "abort: <reason>" when the decode rejects it. Surfaced in
    /// the debug panel so you can see WHY a swing did or didn't register.
    private(set) var lastEmitOutcome: String = "ready"

    /// Fired on main thread when Address is first held (= recording trigger).
    var onAddressHeld: ((_ swingStartBufferIdx: Int) -> Void)?

    /// Fired on main thread once a complete swing has been decoded.
    /// Carries clip-trimmed poses and event frames in clip-local coords.
    var onSwingDetected: (([PoseFrame], SwingEvents) -> Void)?

    /// Fires on main thread alongside `onSwingDetected`, carrying a per-frame
    /// argmax/probability trace for `[swingStart .. emitT]`. Receivers should
    /// dump it to disk for offline comparison against PC v3 sim output.
    var onSwingDiagnostic: ((SwingDiagnostic) -> Void)?

    /// Returns true when voice feedback is currently playing. While this
    /// reports true, the .idle Finish-argmax detector is fully suppressed —
    /// the model keeps producing probs (debug panel still updates) but no
    /// new swing emit can fire. Without this gate, the same swing's lingering
    /// high-Finish posture can re-trigger detection while we're still saying
    /// the previous swing's feedback.
    var isTTSActive: (() -> Bool)?

    // ---- Tunables (mirrors realtime_swing_sim_v3.py) ----
    private let windowSize = 64
    private let strideInf = 8
    private let bufferCapacity = 1200       // ~40 s @ 30 fps
    private let floor: Float = 0.005
    private let quietThr: Float = 0.02
    /// Consecutive Address/Toe-up STRIDES (state machine ticks at stride
    /// frequency = 4 Hz @ 30 fps). 3 strides ≈ 0.8 s — short enough to catch
    /// swings where the player doesn't hold address for a full second.
    private let kAddr = 3
    /// Quiet strides after seen_tail before emit. 5 strides ≈ 1.3 s —
    /// short enough to emit even if the video / session ends right after the swing.
    private let kQuiet = 5
    private let addrLostFrames = 30
    /// Post-emit dead time to debounce the same swing's lingering argmax
    /// from re-triggering. 4 s — what produced 4-of-4 detections cleanly
    /// on the user's test video. NOT used to suppress a real next swing;
    /// user can hit follow-up ~4 s later and we'll still catch it.
    private let cooldownFrames = 120
    /// Additional frames beyond `cooldownFrames` during which we still
    /// respect `isTTSActive` (so detection waits for the previous swing's
    /// feedback to finish). After this grace window we force-unblock —
    /// the `isSpeaking` flag has been observed to get stuck true on
    /// ElevenLabs streaming faults / missed didFinish callbacks, which
    /// would otherwise wedge detection permanently.
    private let ttsGraceFrames = 180
    /// Hard timeout from .swinging start to emit. Real swing + Finish-detection
    /// lag (Finish argmax can take 1-2s to register on device) can easily
    /// take 8-10s in practice. 12s gives generous headroom.
    private let maxSwingFrames = 360
    /// Minimum joint confidence on the address-validating joints (wrists, hips,
    /// shoulders). PoseTCN can land on the Address argmax by chance when there's
    /// no person in frame — this gate kills that. 0.35 is fairly lax; the
    /// distilled YOLO usually gives 0.6+ on a stable address.
    private let personConfThreshold: Float = 0.35
    /// In `addressHeld`, if no subsequent swing-phase argmax appears within this
    /// many frames, we silently drop back to idle WITHOUT cooldown — the user
    /// might just be standing or doing a practice rehearsal, and the next try
    /// could be the real swing.
    /// Real golf pre-shot routine + setup can take 10-20s; keep this generous.
    private let addressTimeoutFrames = 600   // 20 s @ 30 fps
    /// Probability threshold for direct IDLE → SWINGING entry on mid-swing
    /// argmax. Higher than `floor` to avoid acting on noise. Mirrors PC's
    /// DIRECT_SWING_PROB.
    private let directSwingProb: Float = 0.05
    /// Anti-stuck prob-max bypass for addressHeld → swinging. On device the
    /// golf-distilled YOLO produces slightly shifted keypoints vs the vanilla
    /// YOLO used during PoseTCN training, so the model's argmax can stay on
    /// Address through the entire swing even though the swing-class probs
    /// rise. Watch the MAX of swing-class probs directly — fires when any
    /// crosses this threshold even if Address still wins argmax.
    private let swingProbBypass: Float = 0.10
    /// Companion escape: while in addressHeld, if Address class prob itself
    /// drops below this, the body has clearly left the address pose and a
    /// swing has begun. Independent of which other class wins argmax.
    private let addressDropThr: Float = 0.50

    // -- Address-triggered + Finish-confirmed (with confidence gating) --
    //
    // Per user testing on device: Address and Finish are both stable enough
    // when given time (real address takes ≥ 1 s, finish holds at end of
    // swing). The Address argmax is the natural entry signal even with low
    // peak prob, because real players hold address long enough for the
    // model to register.
    //
    // Flow:
    //   1. .idle  → Address argmax held K strides → .swinging
    //   2. .swinging: track which middle phases (Toe-up..Mid-fl) have been
    //      seen as argmax at least once
    //   3. .swinging: Finish argmax ≥ finishConfirmProb → check confidence
    //      = (# phases seen)/6 ; ≥ minSwingConfidence → emit, else discard
    //      (not really a swing — user might have just walked through frame)
    //   4. Timeout (maxSwingFrames without Finish) → discard back to .idle
    //
    /// Minimum mid-swing phases (Toe-up/Mid-bs/Top/Mid-ds/Impact/Mid-fl)
    /// that must have been argmax for emit to fire. 0.33 ≈ 2/6.
    private let minSwingConfidence: Float = 0.33
    private let finishConfirmProb: Float = 0.05
    /// Swing-evidence gate for the Finish trigger (the "look back at the
    /// preceding events' confidence" idea). Over [swingStart..emit], at least
    /// `minMidEventsForSwing` of the mid-swing classes (toe-up..mid-fl) must
    /// peak above `midEventPeakThr`. Someone walking through frame produces a
    /// noisy Finish with NO backswing/downswing peaks, so it fails this and is
    /// rejected — without leaning on a cooldown band-aid every time.
    private let midEventPeakThr: Float = 0.05
    private let minMidEventsForSwing = 2
    /// Set of phase indices seen as argmax during the current swing.
    /// Kept for backward-compat (still surfaced in debug panel); not used
    /// for gating in the Finish-only flow.
    private var phasesSeenInSwing: Set<Int> = []

    /// Strides where Finish was argmax in a row (debounce noise spikes).
    private var consecFinish: Int = 0
    /// Number of frames before the Finish trigger to include in the swing
    /// clip. 6 sec @ 30 fps = 180 frames — covers Address (≥2s hold) + full
    /// swing + follow-through hold before the Finish argmax fires.
    private let swingClipLookback: Int = 180

    private let evtAddr  = 0
    private let evtToeUp = 1
    private let evtMidBs = 2
    private let evtTop   = 3
    private let evtMidDs = 4
    private let evtImpact = 5
    private let evtMidFl = 6
    private let evtFin   = 7

    private let core: PoseTCNEventDetectorCore?
    private let infQueue = DispatchQueue(label: "swin.LiveSwingTracker.infer", qos: .userInitiated)
    /// Serial queue for the heavy full-clip decode at emit time. Runs OFF the
    /// `lock` (and off the main thread) so pose `ingest()` — which executes on
    /// the main thread (YOLO publishes there) and grabs `lock` every frame —
    /// is never blocked behind a 1–2 s CoreML decode. That blocking was what
    /// froze the UI ("can't exit, must kill the app") after the first swing.
    private let emitQueue = DispatchQueue(label: "swin.LiveSwingTracker.emit", qos: .userInitiated)
    private let lock = NSLock()
    private var buffer: [PoseFrame] = []
    /// Per-frame 9-class probs, indexed in absolute buffer space. nil for
    /// frames not yet covered by any inference.
    private var liveProbs: [[Float]?] = []
    private var lastInferAt = 0

    // state-machine bookkeeping (mutated under lock)
    private var consecAddr = 0
    private var consecQuiet = 0
    private var consecAddrLost = 0
    /// Mid-fl or Finish argmax above floor was seen this swing. Required for
    /// the "address-after-tail" short-circuit emit (next swing's setup detected
    /// while still in SWINGING).
    private var seenTail = false
    /// Impact, Mid-fl, or Finish argmax above floor was seen this swing.
    /// Required for the main K_QUIET emit path — distinguishes a real downswing
    /// (Impact fires) from a half-swing that aborts before impact.
    private var seenCompletion = false
    private var swingStart = -1
    private var swingingSince = -1
    private var cooldownUntil = -1
    private var addressEnteredAtFrame = -1

    init() {
        self.core = try? PoseTCNEventDetectorCore()
        if core == nil { print("[LiveSwingTracker] PoseTCN unavailable") }
    }

    /// Walk backward through liveProbs from frame `t` looking for the most
    /// likely Address frame (where Address-class probability peaked).
    /// Returns the frame index, or `fallback` if no good candidate found.
    ///
    /// Used when a swing is detected mid-flight (direct entry from IDLE on
    /// Mid-bs/Top/Mid-ds/Impact) — we want the saved clip to start from
    /// Address, not from the moment we noticed the swing was already in progress.
    private func rewindToAddressLocked(from t: Int, fallback: Int,
                                        maxLookback: Int = 90) -> Int {
        // Search a window of `maxLookback` frames before `t` (~3 sec @ 30fps).
        let lo = max(0, t - maxLookback)
        var bestIdx = fallback
        var bestProb: Float = 0.0
        for k in stride(from: t - 1, through: lo, by: -1) {
            guard let p = liveProbs[k] else { continue }
            // Look for Address-class peak. We accept any prob above a small
            // threshold; we want the BEST Address frame in the window.
            let pAddr = p[evtAddr]
            if pAddr > bestProb {
                bestProb = pAddr
                bestIdx = k
            }
        }
        return bestIdx
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
        liveProbs.removeAll(keepingCapacity: true)
        consecAddr = 0; consecQuiet = 0; consecAddrLost = 0
        seenTail = false; seenCompletion = false; swingStart = -1
        swingingSince = -1; cooldownUntil = -1
        addressEnteredAtFrame = -1
        // CRITICAL: reset `lastInferAt` along with the buffer. The stride
        // gate is `bufCount - lastInferAt >= strideInf`; without this,
        // session 2 starts with bufCount=1 and a stale lastInferAt of ~1192
        // (session 1's tail), so inference doesn't fire until ~40 s later.
        // Same logic for `state` — `publishState(.idle)` below is async on
        // main, so without a direct sync assignment, stepStateLocked can
        // observe the previous session's terminal state for several ticks.
        lastInferAt = 0
        state = .idle
        phasesSeenInSwing.removeAll(keepingCapacity: true)
        consecFinish = 0
        DispatchQueue.main.async { self.currentPhasesSeen = 0 }
        publishState(.idle)
        publishLiveFrames(Array(repeating: -1, count: 8))
    }

    func ingest(_ pose: PoseFrame) {
        lock.lock()
        buffer.append(pose)
        liveProbs.append(nil)
        if buffer.count > bufferCapacity {
            let drop = buffer.count - bufferCapacity
            buffer.removeFirst(drop)
            liveProbs.removeFirst(drop)
            if swingStart >= 0   { swingStart   = max(0, swingStart - drop) }
            if swingingSince >= 0 { swingingSince = max(0, swingingSince - drop) }
            if cooldownUntil >= 0 { cooldownUntil = max(0, cooldownUntil - drop) }
            lastInferAt = max(0, lastInferAt - drop)
        }
        let bufCount = buffer.count
        let t = bufCount - 1
        let shouldRun = (core != nil)
            && bufCount >= 16
            && bufCount - lastInferAt >= strideInf
        if shouldRun {
            lastInferAt = bufCount
            let start = max(0, bufCount - windowSize)
            let snapshot = Array(buffer[start..<bufCount])
            // Frame BEFORE the snapshot, used by v3.1 to compute the correct
            // frame-to-frame velocity for snapshot[0]. Without this the first
            // frame of every 64-frame window has vel=0 (a feature artifact the
            // TCN's receptive field then propagates to the output at currentT).
            let preCtx: PoseFrame? = (start > 0) ? buffer[start - 1] : nil
            lock.unlock()
            infQueue.async { [weak self] in
                self?.runInferenceAndStep(snapshot: snapshot,
                                          previousPose: preCtx,
                                          snapshotStart: start,
                                          currentT: t)
            }
        } else {
            // step the state machine using the latest existing probs
            stepStateLocked(at: t)
            lock.unlock()
        }
    }

    // MARK: - inference + state machine

    private static var didLogFirstInfer = false

    private func runInferenceAndStep(snapshot: [PoseFrame],
                                     previousPose: PoseFrame?,
                                     snapshotStart: Int,
                                     currentT: Int) {
        guard let core else { return }
        let probs = core.inferWindow(snapshot, previousPose: previousPose) // (n, 9)
        // ONE-SHOT: dump the very first inference's last-frame probs + a couple
        // of normalized features so we can see whether the model is producing
        // plausible output or just garbage on device.
        if !LiveSwingTracker.didLogFirstInfer, let last = probs.last,
           let firstSnap = snapshot.first {
            LiveSwingTracker.didLogFirstInfer = true
            let lh = firstSnap.keypoints[Joint.leftHip]
            let rh = firstSnap.keypoints[Joint.rightHip]
            let ls = firstSnap.keypoints[Joint.leftShoulder]
            let rs = firstSnap.keypoints[Joint.rightShoulder]
            dbg(tag: "track", String(format: "FIRST-INFER snapCount=%d "
                + "lh=(%.4f,%.4f) rh=(%.4f,%.4f) ls=(%.4f,%.4f) rs=(%.4f,%.4f)",
                snapshot.count, lh.x, lh.y, rh.x, rh.y, ls.x, ls.y, rs.x, rs.y))
            dbg(tag: "track", String(format: "FIRST-INFER probs "
                + "A=%.3f TU=%.3f MB=%.3f Top=%.3f MD=%.3f I=%.3f MF=%.3f F=%.3f noEv=%.3f",
                last[0], last[1], last[2], last[3], last[4],
                last[5], last[6], last[7], last[8]))
        }
        lock.lock()
        let bufCount = buffer.count
        let endValid = min(snapshotStart + probs.count, bufCount, liveProbs.count)
        var i = 0
        for absFrame in snapshotStart..<endValid {
            liveProbs[absFrame] = probs[i]
            i += 1
        }
        // Step the state machine ONCE per stride at currentT, matching the
        // PC v3 sim's `for t in range(N): if t % STRIDE_INF == 0: ...` loop.
        // Stepping each frame in the stride would let consec_* counters
        // increment 8x faster than on PC, making K_ADDR / K_QUIET fire on
        // a fraction of the intended time window — that's what was producing
        // false-positive emits on incidental ball-scoop motion.
        if currentT < bufCount {
            stepStateLocked(at: currentT)
        }
        let stateNow = state
        let liveFramesNow = currentLiveFramesLocked()
        lock.unlock()
        publishState(stateNow)
        publishLiveFrames(liveFramesNow)
    }

    /// Advance the state machine using the probs at `t` if available.
    /// Mutates state variables under lock. Emits onSwingDetected / onAddressHeld
    /// asynchronously when triggered.
    private func stepStateLocked(at t: Int) {
        guard t >= 0, t < liveProbs.count, let p = liveProbs[t] else { return }
        let (argmax8, probA) = argmaxOver8(p)
        currentArgmax = (probA >= floor) ? argmax8 : -1
        let above = probA >= floor

        // Surface latest probs to UI + disk log so user can see signal strength.
        let probsCopy = Array(p.prefix(8))
        DispatchQueue.main.async {
            self.currentProbs = probsCopy
            self.recentProbsHistory.append((t: t, probs: probsCopy))
            if self.recentProbsHistory.count > self.probsHistoryCapacity {
                self.recentProbsHistory.removeFirst(
                    self.recentProbsHistory.count - self.probsHistoryCapacity)
            }
        }
        appendToProbsLog(t: t, probs: probsCopy)

        // Finish-only state machine. Per on-device testing, Finish argmax is
        // the most stable signal of all 8 events. Address/middle phases are
        // unreliable. We ignore them entirely and just wait for a debounced
        // Finish argmax, then take a fixed window before that frame as the
        // clip and run full-clip PoseTCN to back-fill all 8 events.
        switch state {
        case .idle:
            if t <= cooldownUntil { return }
            // Soft block: wait for the previous swing's TTS to finish, but
            // only within a bounded grace window past the hard cooldown.
            // Beyond `ttsGraceFrames`, force-unblock even if isSpeaking is
            // still true — protects us from a stuck TTSService.isSpeaking
            // wedging detection forever.
            let ttsCeiling = cooldownUntil + ttsGraceFrames
            if t <= ttsCeiling, isTTSActive?() == true {
                consecFinish = 0
                return
            }
            if t > ttsCeiling, isTTSActive?() == true {
                dbg(.warn, tag: "track",
                    "TTS grace exceeded @ t=\(t) (ceiling=\(ttsCeiling)) — unblocking despite isSpeaking=true")
            }
            if !hasPersonAt(t) { consecFinish = 0; return }

            // Debounced Finish argmax: must be argmax for 2 consecutive strides.
            let finishIsArgmax = above && argmax8 == evtFin
            if finishIsArgmax {
                consecFinish += 1
                if consecFinish >= 2 {
                    // Take a fixed window ending at this Finish frame.
                    let clipStart = max(0, t - swingClipLookback)
                    swingStart = clipStart
                    dbg(tag: "track", String(format:
                        "Finish argmax debounced @ %d (p=%.3f) → emit clip [%d..%d]",
                        t, p[evtFin], clipStart, t))
                    consecFinish = 0
                    emitSwingLocked(currentT: t)
                }
            } else {
                consecFinish = 0
            }

        case .addressHeld, .swinging:
            // Legacy states are no longer entered (Finish-only flow uses only
            // .idle/.cooldown). Force back to .idle if we ever land here.
            state = .idle
            consecAddr = 0
            consecFinish = 0
            phasesSeenInSwing.removeAll(keepingCapacity: true)
            addressEnteredAtFrame = -1

        case .cooldown:
            // TTS feedback debounce. Just wait until cooldownUntil; then back
            // to .idle for the next Finish. No bypass paths — the
            // single-trigger Finish flow is much simpler to reason about.
            if t > cooldownUntil {
                state = .idle
                consecFinish = 0
            }
        }
    }

    /// Called from stepStateLocked when emit conditions are met. Two-stage
    /// clip extraction:
    ///   (1) WIDE: take buffer[swingStart-5 .. t+5] (~6 sec of context)
    ///   (2) Decode events on WIDE clip via PoseTCNEventDetector
    ///   (3) TRIM the saved clip to [Address .. Finish] from (2)'s output,
    ///       so the persisted clip only contains the actual swing — not the
    ///       3-5 sec of standing-around before Address.
    ///   (4) Re-index events to the TRIMMED clip's local coordinates
    private func emitSwingLocked(currentT t: Int) {
        // CHEAP work under the lock: snapshot the wide clip, capture the
        // diagnostic trace, and FREEZE the state machine to .cooldown right now
        // (debounce — whether or not the decode confirms a real swing, the
        // lingering posture shouldn't re-trigger). The heavy full-clip CoreML
        // decode is dispatched to `emitQueue` so it runs OFF this lock and off
        // the main thread — pose ingest() (main thread) no longer stalls behind it.
        let wideStart = max(0, swingStart - 5)
        let wideEnd = min(buffer.count, t + 5)
        let widePoses = Array(buffer[wideStart..<wideEnd])
        let swingStartSnap = swingStart
        let trace = captureTraceLocked(from: swingStart, throughInclusive: t)
        let swingNo = swingCount + 1

        // Swing-evidence gate — look back from the Finish trigger at the
        // mid-swing events' peak confidence over [swingStart..t]. A real swing
        // leaves peaks in toe-up..mid-fl; walking through frame gives only a
        // noisy Finish with no backswing/downswing peaks. Reject the emit (and
        // briefly cooldown so the same posture doesn't immediately re-trigger).
        let midEvents = [evtToeUp, evtMidBs, evtTop, evtMidDs, evtImpact, evtMidFl]
        let lookbackLo = max(0, swingStart)
        var midPeaked = 0
        if lookbackLo <= t {
            for e in midEvents {
                var peak: Float = 0
                for fr in lookbackLo...min(t, liveProbs.count - 1) {
                    if let p = liveProbs[fr], p[e] > peak { peak = p[e] }
                }
                if peak >= midEventPeakThr { midPeaked += 1 }
            }
        }
        if midPeaked < minMidEventsForSwing {
            dbg(.warn, tag: "track", "ABORT emit @ \(t) — weak swing evidence: "
                + "\(midPeaked)/\(midEvents.count) mid-events peaked over "
                + "[\(lookbackLo)..\(t)] (walking through frame?).")
            state = .cooldown
            cooldownUntil = t + cooldownFrames
            consecFinish = 0
            DispatchQueue.main.async {
                self.lastEmitOutcome = "abort: weak evidence (\(midPeaked) mid-events)"
            }
            return
        }

        state = .cooldown
        cooldownUntil = t + cooldownFrames
        consecAddr = 0
        consecQuiet = 0
        seenTail = false
        seenCompletion = false
        swingingSince = -1
        phasesSeenInSwing.removeAll(keepingCapacity: true)
        consecFinish = 0
        DispatchQueue.main.async { self.currentPhasesSeen = 0 }

        emitQueue.async { [weak self] in
            self?.decodeAndEmit(widePoses: widePoses, wideStart: wideStart,
                                swingStartAbs: swingStartSnap, emitT: t,
                                swingNumber: swingNo, trace: trace)
        }
    }

    /// Heavy emit work — runs on `emitQueue`, NOT under `lock`, NOT on main.
    /// Full-clip decode → trim to [Address..Finish] → publish, or abort silently
    /// (the state machine was already frozen to .cooldown by the caller).
    private func decodeAndEmit(widePoses: [PoseFrame], wideStart: Int,
                              swingStartAbs: Int, emitT t: Int,
                              swingNumber swingNo: Int,
                              trace: [SwingDiagnostic.TraceEntry]) {
        // Build the detector fresh each emit — caching it across emits crashed
        // on the second swing on device (suspected MLModel state corruption).
        let detector = try? PoseTCNEventDetector()
        let wideEvents = detector?.detect(widePoses) ?? SwingEvents.undetected

        // ORIGINAL gate (unchanged): a clean Address+Finish pair from the
        // full-clip decode. If the decoder can't find one, this wasn't a real
        // swing — abort. (No extra middle-event / duration checks — those were
        // my over-tightening and are reverted.)
        let a = wideEvents.frame(for: .address)
        let f = wideEvents.frame(for: .finish)
        guard let a, let f, a >= 0, f > a, f < widePoses.count else {
            dbg(.warn, tag: "track", "ABORT emit @ \(t) — no Address+Finish pair "
                + "(addr=\(String(describing: a)) fin=\(String(describing: f))).")
            DispatchQueue.main.async { self.lastEmitOutcome = "abort: no Address+Finish" }
            return
        }
        let span = f - a
        let trimStartLocal = max(0, a - 5)
        let trimEndLocal   = min(widePoses.count, f + 5)
        let poses = Array(widePoses[trimStartLocal..<trimEndLocal])
        let events = SwingEvents(frames: wideEvents.frames.map { ff -> Int in
            guard ff >= 0 else { return -1 }
            let shifted = ff - trimStartLocal
            return (shifted >= 0 && shifted < poses.count) ? shifted : -1
        }, handedness: wideEvents.handedness)

        let clipStart = wideStart + trimStartLocal
        let clipEnd   = wideStart + trimEndLocal
        let absEvents = events.frames.map { $0 >= 0 ? clipStart + $0 : -1 }
        let diag = SwingDiagnostic(
            swingNumber: swingNo, swingStartAbsolute: swingStartAbs,
            emitFrameAbsolute: t, clipStartAbsolute: clipStart, clipEndAbsolute: clipEnd,
            eventsClipLocal: events.frames, eventsAbsolute: absEvents,
            seenTail: false, emitReason: "finish-trigger (trim addr→fin)",
            argmaxTrace: trace)
        dbg(tag: "track", "EMIT swing #\(swingNo) [\(clipStart)..\(clipEnd)] events=\(absEvents)")

        DispatchQueue.main.async {
            self.swingCount = swingNo
            self.liveEventFrames = absEvents
            self.lastEmitOutcome = "EMIT #\(swingNo) span=\(span)f"
            self.onSwingDetected?(poses, events)
            self.onSwingDiagnostic?(diag)
        }
    }

    /// Build the per-frame argmax/probMax trace over the swinging window.
    /// Called under lock; reads `liveProbs` which is mutated only under lock.
    private func captureTraceLocked(from fromIdx: Int,
                                    throughInclusive toIdx: Int) -> [SwingDiagnostic.TraceEntry] {
        guard fromIdx >= 0, toIdx >= fromIdx else { return [] }
        var out: [SwingDiagnostic.TraceEntry] = []
        out.reserveCapacity(toIdx - fromIdx + 1)
        for f in fromIdx...min(toIdx, liveProbs.count - 1) {
            if let probs = liveProbs[f] {
                let (am, pm) = argmaxOver8(probs)
                out.append(.init(frame: f, argmax: am, probMax: pm))
            } else {
                out.append(.init(frame: f, argmax: -1, probMax: 0))
            }
        }
        return out
    }

    /// True if there's actually a body in frame at buffer index `t` — checks
    /// the joints that an "Address" should rely on (wrists + hips + shoulders).
    /// If pose extraction can't see them with reasonable confidence, the
    /// PoseTCN argmax is meaningless.
    private func hasPersonAt(_ t: Int) -> Bool {
        guard t >= 0, t < buffer.count else { return false }
        let p = buffer[t]
        let needed = [Joint.leftWrist, Joint.rightWrist,
                      Joint.leftHip, Joint.rightHip,
                      Joint.leftShoulder, Joint.rightShoulder]
        for j in needed where p.confidences[j] < personConfThreshold {
            return false
        }
        return true
    }

    private func argmaxOver8(_ p: [Float]) -> (Int, Float) {
        var best = 0
        var bestV = p[0]
        for c in 1..<8 where p[c] > bestV {
            bestV = p[c]; best = c
        }
        return (best, bestV)
    }

    private func currentLiveFramesLocked() -> [Int] {
        return liveEventFrames
    }

    private func publishState(_ s: State) {
        DispatchQueue.main.async { self.state = s }
    }
    private func publishLiveFrames(_ frames: [Int]) {
        DispatchQueue.main.async { self.liveEventFrames = frames }
    }

    // MARK: - Probs CSV logging
    //
    // Lets user enable a disk log of (frame_index, argmax, p_address, p_toeup,
    // …, p_finish) per inference, so we can debug why triggers are sparse on
    // their phone hardware. File lives in app Documents and is shareable via
    // Files app / AirDrop / iCloud Drive. One CSV per session.

    /// Begin appending per-inference probs to a CSV in the app's Documents
    /// directory. Returns the URL of the created file, or nil on failure.
    @discardableResult
    func startProbsLogging() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory,
                                  in: .userDomainMask).first else { return nil }
        let logsDir = docs.appendingPathComponent("posetcn_logs", isDirectory: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = logsDir.appendingPathComponent("probs_\(ts).csv")
        let header = "t,argmax,p_address,p_toeup,p_midbs,p_top,p_midds,p_impact,p_midfl,p_finish\n"
        do {
            try header.write(to: url, atomically: true, encoding: .utf8)
            self.probsLogURL = url
            dbg(tag: "track", "probs log started: \(url.lastPathComponent)")
            return url
        } catch {
            dbg(.warn, tag: "track", "probs log create failed: \(error)")
            return nil
        }
    }

    /// Stop appending and forget the file.
    func stopProbsLogging() {
        if let u = probsLogURL {
            dbg(tag: "track", "probs log stopped: \(u.lastPathComponent)")
        }
        probsLogURL = nil
    }

    private func appendToProbsLog(t: Int, probs: [Float]) {
        guard let url = probsLogURL else { return }
        let (a, _) = argmaxOver8(probs)
        let probsStr = probs.prefix(8)
            .map { String(format: "%.4f", $0) }
            .joined(separator: ",")
        let line = "\(t),\(a),\(probsStr)\n"
        if let data = line.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }
}

// MARK: - PoseTCN core inference helper (unchanged)

final class PoseTCNEventDetectorCore: @unchecked Sendable {
    private let model: PoseTCN_v3_1
    let windowSize = 64
    // v3.1 input dim: 51 (pos+conf) + 51 (frame-to-frame Δ) = 102
    private let posDim = 51
    private let featDim = 102

    static var didLogFirstLogits = false

    init() throws {
        let config = MLModelConfiguration()
        // Force CPU+GPU (skip Neural Engine). ANE was returning real logits at
        // only some positions and zeros elsewhere for this PoseTCN export,
        // making softmax uniform (1/9) on the positions state-machine reads.
        // CPU+GPU matches Mac CoreML behavior (which we verified == PyTorch).
        #if targetEnvironment(simulator)
        // Simulator's MPS/GPU backend is "incompatible OS" (E5RT/Espresso
        // exception) and returns garbage logits → no detection. CPU-only is
        // valid on the sim so the live pipeline can be tested without a device.
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .cpuAndGPU
        #endif
        self.model = try PoseTCN_v3_1(configuration: config)
    }

    /// Returns per-frame (probs over 9 classes) for ≤64 input frames.
    /// Right-pads with the last frame to reach 64.
    /// `previousPose` (if any) is the frame immediately before `poses[0]` in
    /// the live buffer — used so `vel(0) = pos(0) - pos(previous)` matches PC
    /// where features are pre-computed over the whole video, not per-window.
    func inferWindow(_ poses: [PoseFrame], previousPose: PoseFrame? = nil) -> [[Float]] {
        let n = poses.count
        guard n > 0 else { return [] }
        let feats = normalizedFeatures(from: poses, previousPose: previousPose)  // (n * 102)
        guard let arr = try? MLMultiArray(shape: [1, 64, NSNumber(value: featDim)],
                                          dataType: .float32) else {
            return Array(repeating: [Float](repeating: 0, count: 9), count: n)
        }
        let dst = arr.dataPointer.bindMemory(to: Float.self, capacity: 64 * featDim)
        for t in 0..<windowSize {
            let srcFrameIdx = min(t, n - 1)
            let srcOffset = srcFrameIdx * featDim
            for f in 0..<featDim { dst[t * featDim + f] = feats[srcOffset + f] }
        }
        let output: PoseTCN_v3_1Output
        do {
            output = try model.prediction(input: PoseTCN_v3_1Input(pose_seq: arr))
        } catch {
            dbg(tag: "track", "PoseTCN_v3_1 prediction FAILED: \(error)")
            return Array(repeating: [Float](repeating: 0, count: 9), count: n)
        }
        // Use MLMultiArray's NSNumber subscript instead of raw dataPointer.
        // dataPointer + manual stride arithmetic was unreliable: padded ANE
        // strides + private internal layouts meant my reads landed in
        // padding zones, producing softmax-of-zeros = 1/9 uniform regardless
        // of what the model actually output. Subscript access defers to
        // MLMultiArray's own indexing logic which always returns the correct
        // logit for [batch, time, class].
        let outStride1 = output.logits.strides.count > 1 ? output.logits.strides[1].intValue : 9
        let totalFloats = 64 * max(outStride1, 9)
        let src = output.logits.dataPointer.bindMemory(to: Float.self, capacity: totalFloats)
        if !PoseTCNEventDetectorCore.didLogFirstLogits {
            PoseTCNEventDetectorCore.didLogFirstLogits = true
            let outStrides = output.logits.strides
            let inStrides = arr.strides
            dbg(tag: "track", "v3_1 IN  shape=\(arr.shape) strides=\(inStrides)")
            dbg(tag: "track", "v3_1 OUT shape=\(output.logits.shape) strides=\(outStrides) count=\(output.logits.count)")
            // Sample via NSNumber subscript (canonical access path):
            for t in [0, 1, 7, 15, 31, 47, 63] {
                let row = (0..<9).map { c -> String in
                    let v = output.logits[[0, NSNumber(value: t), NSNumber(value: c)]].floatValue
                    return String(format: "%.2f", v)
                }.joined(separator: ",")
                dbg(tag: "track", "v3_1 OUT[sub] t=\(t) [\(row)]")
            }
            // Also dump input first frame's first 12 floats to verify writes
            let inSamp0 = (0..<12).map { String(format: "%.3f", dst[$0]) }.joined(separator: ",")
            let inSampN = (0..<12).map { String(format: "%.3f", dst[(n - 1) * featDim + $0]) }.joined(separator: ",")
            dbg(tag: "track", "v3_1 IN  t=0 [\(inSamp0)…]  t=\(n-1) [\(inSampN)…] n=\(n)")
            // SANITY: directly compute softmax for t=n-1 using the fix and
            // dump it so we can compare against the addressHeld per-stride
            // print. If this shows non-uniform but addressHeld shows 0.111,
            // the build is cached and we're seeing stale binary.
            var probeLogits = [Float](repeating: 0, count: 9)
            for c in 0..<9 {
                probeLogits[c] = output.logits[[0, NSNumber(value: n - 1), NSNumber(value: c)]].floatValue
            }
            let probeProbs = softmax(probeLogits)
            let probeStr = probeProbs.map { String(format: "%.3f", $0) }.joined(separator: ",")
            dbg(tag: "track", "v3_1 PROBE[sub] t=\(n-1) probs=[\(probeStr)]")
        }
        var probs = [[Float]](); probs.reserveCapacity(n)
        for t in 0..<n {
            var logits = [Float](repeating: 0, count: 9)
            for c in 0..<9 {
                let idx: [NSNumber] = [0, NSNumber(value: t), NSNumber(value: c)]
                logits[c] = output.logits[idx].floatValue
            }
            probs.append(softmax(logits))
        }
        return probs
    }

    private func softmax(_ x: [Float]) -> [Float] {
        let m = x.max() ?? 0
        var ex = x.map { expf($0 - m) }
        let s = ex.reduce(0, +)
        if s > 0 { for i in 0..<ex.count { ex[i] /= s } }
        return ex
    }

    /// v3.1 features: per-frame [pos+conf (51)] then [frame-to-frame Δ (51)].
    /// Matches PC `feats_v3` exactly: pos = (kp - hip_mid) / torso_scale per
    /// frame, then vel[i] = pos[i] - pos[i-1]. If `previousPose` is supplied,
    /// frame 0's velocity uses it (matches PC's whole-video pre-computation);
    /// otherwise frame 0's velocity block is zeros (matches PC's first video
    /// frame only).
    private func normalizedFeatures(from poses: [PoseFrame],
                                    previousPose: PoseFrame?) -> [Float] {
        let n = poses.count
        // Normalize all frames first (including previousPose at index -1 if
        // provided), into a flat (1+n) * posDim array offset by 1.
        let hasPrev = previousPose != nil
        let totalRows = n + (hasPrev ? 1 : 0)
        var pos = [Float](repeating: 0, count: totalRows * posDim)
        let allPoses: [PoseFrame] = hasPrev ? ([previousPose!] + poses) : poses
        for (i, pose) in allPoses.enumerated() {
            // Aspect compensation: anisotropic keypoints (kp.x in [0,1] of W,
            // kp.y in [0,1] of H) need x scaled by W/H so distances are in
            // shared pixel/H units, matching PoseTCN's PC training pipeline.
            // Legacy iso poses already share units → ax = 1.
            let ax = pose.isoNormalized ? Float(1) : pose.imageAspect
            let lhip = pose.keypoints[Joint.leftHip]
            let rhip = pose.keypoints[Joint.rightHip]
            let lsh = pose.keypoints[Joint.leftShoulder]
            let rsh = pose.keypoints[Joint.rightShoulder]
            let hipMidX = ((lhip.x + rhip.x) / 2) * ax
            let hipMidY = (lhip.y + rhip.y) / 2
            let shMidX  = ((lsh.x + rsh.x) / 2) * ax
            let shMidY  = (lsh.y + rsh.y) / 2
            let dx = shMidX - hipMidX
            let dy = shMidY - hipMidY
            let scale = max(sqrt(dx * dx + dy * dy), 1e-6)
            let base = i * posDim
            for j in 0..<17 {
                let kp = pose.keypoints[j]
                pos[base + j * 3 + 0] = (kp.x * ax - hipMidX) / scale
                pos[base + j * 3 + 1] = (kp.y - hipMidY) / scale
                pos[base + j * 3 + 2] = pose.confidences[j]
            }
        }
        var feats = [Float](repeating: 0, count: n * featDim)
        let offset = hasPrev ? 1 : 0
        for i in 0..<n {
            let inBase = (i + offset) * posDim
            let outBase = i * featDim
            for k in 0..<posDim { feats[outBase + k] = pos[inBase + k] }
            // velocity: pos[i+offset] - pos[i+offset-1]; for i=0 without prev,
            // leave the Δ block at zeros (matches PC's vel[0] = 0).
            if (i + offset) > 0 {
                let prevBase = (i + offset - 1) * posDim
                for k in 0..<posDim {
                    feats[outBase + posDim + k] = pos[inBase + k] - pos[prevBase + k]
                }
            }
        }
        return feats
    }
}

// MARK: - SwingDiagnostic

/// Per-emit forensic record from LiveSwingTracker. Persisted next to the
/// archived swing so we can diff iOS detections against PC v3 sim output
/// when a false positive (or missed swing) is reported.
struct SwingDiagnostic: Sendable, Codable {
    /// Per-frame argmax8 + max-class prob, one entry per buffer frame in
    /// `[swingStart .. emitFrame]`.
    struct TraceEntry: Sendable, Codable {
        let frame: Int          // absolute buffer frame index
        let argmax: Int         // 0..7 over the 8 event classes, -1 if no probs
        let probMax: Float      // probability of the argmax class
    }

    let swingNumber: Int
    let swingStartAbsolute: Int
    let emitFrameAbsolute: Int
    let clipStartAbsolute: Int
    let clipEndAbsolute: Int
    let eventsClipLocal: [Int]
    let eventsAbsolute: [Int]
    let seenTail: Bool
    let emitReason: String          // "tail-seen" | "fallback-quiet"
    let argmaxTrace: [TraceEntry]
}
