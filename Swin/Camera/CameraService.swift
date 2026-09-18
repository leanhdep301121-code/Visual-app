import AVFoundation
import CoreImage
import CoreMotion
import Observation
import UIKit

@Observable
final class CameraService: NSObject {
    enum State: Equatable {
        case idle
        case configuring
        case denied
        case ready
        case recording
        case error(String)
    }

    var state: State = .idle
    var position: CameraPosition = .back
    var lastRecordingURL: URL?

    /// Which capture graph is running. `.analysis` (default) = single wide
    /// camera + the full pose/event/coaching pipeline — the app's existing
    /// behaviour, unchanged. `.multiAngle` / `.cinematic` are opt-in shooting
    /// modes that only appear on capable hardware (the wide stream still drives
    /// analysis in every mode, so coaching/archive never stop).
    private(set) var captureMode: CaptureMode = .analysis
    /// What THIS device can actually run. On the simulator / non-Pro this
    /// reports only `.analysis`, so the mode switcher shows nothing extra.
    @ObservationIgnored let captureCaps = CaptureCapabilities.detect()

    /// The capture session. A `var` (not `let`) because switching to
    /// `.multiAngle` rebuilds it as an `AVCaptureMultiCamSession` (a subclass).
    /// `@ObservationIgnored` is LOAD-BEARING: `rebuildSession` reassigns it on a
    /// background queue, and mutating an *observed* property off the main thread
    /// while SwiftUI reads it on main is a data race → the multi-angle crash.
    /// (CaptureController marks its session ignored for the same reason.) The
    /// preview rebinds via the observed `captureMode` change instead.
    @ObservationIgnored private(set) var session = AVCaptureSession()
    /// Telephoto preview frame, published only in `.multiAngle` (the wide
    /// stream still drives the main preview + all analysis). nil otherwise.
    var telePreview: CGImage?
    @ObservationIgnored private let teleOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private var teleFocus: SubjectFocusController?
    @ObservationIgnored private var lastTelePreviewAt: CFTimeInterval = 0
    @ObservationIgnored private let previewCIContext = CIContext(options: [.useSoftwareRenderer: false])
    let poseService: PoseService
    let swingRecorder = SwingRecorder()
    let swingDetector = SwingDetector()
    let liveTracker = LiveSwingTracker()
    /// Live face-exposure helper: measures the golfer's face brightness and
    /// auto-pulls exposure up when the face is dark/backlit (background may blow
    /// out — that's fine). Guidance + condition surfaced in RecordView.
    let lighting = LightingAdvisor()
    @ObservationIgnored private var subjectFocus: SubjectFocusController?
    private var frameCounter: Int64 = 0

    /// Fires on main thread for each detected swing with the freshly-built
    /// (report, score). Goes through this closure rather than the @Observable
    /// `swingRecorder.report` slot — that slot is single-valued and gets
    /// overwritten if two swings emit before the consumer's onChange handler
    /// runs, which led to "swing 2 archived with swing 3's poses" races.
    var onLiveSwing: ((SwingReport, SwingScore) -> Void)?

    /// When false, captureOutput stops handing frames to YOLO/PoseTCN.
    /// Used by PowerBench to isolate camera-only cost vs full-pipeline cost.
    var inferenceEnabled: Bool = true

    #if targetEnvironment(simulator)
    /// 模拟器没真摄像头（AVCaptureDevice 为 nil）：用一段打包视频冒充摄像头，
    /// 帧既喂进姿态管线（和真机 captureOutput 同一条路），又发布出来当预览。
    var simFrame: CGImage?
    @ObservationIgnored private var simTask: Task<Void, Never>?
    @ObservationIgnored private let simCIContext = CIContext()
    #endif

    /// The virtual-camera video is already portrait, so its chunk recorder
    /// must skip the landscape→portrait rotation a real sensor needs. Set true
    /// on the simulator path; false on a real device.
    @ObservationIgnored private var recordingSourceIsPortrait = false

    private let sessionQueue = DispatchQueue(label: "com.swin.camera.session", qos: .userInitiated)
    /// One-shot guard for intrinsics persistence (per app run).
    private var didPersistIntrinsics = false
    private let videoQueue = DispatchQueue(label: "com.swin.camera.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.swin.camera.audio", qos: .userInitiated)

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    // `var` (not `let`): switching capture mode rebuilds the session with a
    // fresh wide output. captureOutput identifies the wide stream by `===` on
    // the CURRENT instance, so analysis follows the output across rebuilds.
    private var videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    private let recorderLock = NSLock()
    private var recorder: VideoRecorder?

    /// Chunked session recording. Instead of one giant mp4 covering the
    /// whole session, we rotate writers every `chunkDurationSeconds` so
    /// each chunk can be finalized + per-swing-clipped IN THE BACKGROUND
    /// while the session is still running. At session end only the LAST
    /// chunk's swings remain to be exported — most clip work is already
    /// done. Trade-off: chunk swap costs a tiny bit of encoder/file IO
    /// every minute, and a swing that spans a chunk boundary is rare
    /// (we delay swaps while the tracker isn't `.idle`).
    private let sessionRecorderLock = NSLock()
    private var currentChunkRecorder: VideoRecorder?
    private(set) var currentChunkURL: URL?
    /// PTS (in seconds, camera-session time base) of the first sample
    /// buffer the CURRENT chunk's writer saw. This is the chunk-local
    /// time origin — clip ranges for swings in this chunk subtract it.
    private(set) var currentChunkFirstPTSSeconds: Double?
    /// Wall-clock time when the CURRENT chunk started. Used to decide
    /// when to roll over to a new chunk.
    private(set) var currentChunkStartedAt: Date?
    /// Wall-clock time when the SESSION started (first chunk opened).
    /// Kept separately so external callers (FeedbackOrchestrator) can
    /// report a stable "session start" even across chunk boundaries.
    private(set) var sessionRecordingStartedAt: Date?
    /// How long each chunk runs before we trigger a swap. 60 s is a good
    /// trade-off — large enough to almost always fit a single swing in
    /// one chunk, small enough that the per-swing clipping queue stays
    /// short throughout the session.
    private let chunkDurationSeconds: TimeInterval = 60
    /// Early-roll floor: once a swing's clip is queued we roll the chunk as
    /// soon as the tracker is idle, so the mp4 lands seconds after the swing
    /// (in-session replay needs it) instead of up to `chunkDurationSeconds`
    /// later. The floor just stops thrash when swings come back-to-back.
    private let minChunkSecondsBeforeEarlyRoll: TimeInterval = 5
    /// Asked (off-lock) whether the CURRENT chunk already has a swing clip
    /// queued in SwingArchive. Wired by RecordView. Gating the early roll on
    /// this avoids a data-loss race: rolling before the archive queues the
    /// clip means `onChunkClosed` exports nothing and then deletes the chunk.
    var chunkHasQueuedClips: ((URL) -> Bool)?
    /// Prevents re-entrant swaps — captureOutput can fire many times per
    /// second, only the first call past the threshold actually triggers.
    private var chunkSwapInFlight: Bool = false
    /// Fired (on a background queue) whenever a chunk's mp4 is fully
    /// finalized and ready for clip extraction. RecordView wires this to
    /// SwingArchive.onChunkClosed so PendingClips drain incrementally
    /// instead of all-at-once at session end.
    var onChunkClosed: ((URL) -> Void)?

    private var videoSize = CGSize(width: 1920, height: 1080)

    override init() {
        // Try YOLO11n-pose-golf first; fall back to Apple Vision if mlmodel missing
        let pose: PoseService
        if let yolo = try? YoloPoseService() {
            pose = yolo
            print("[CameraService] pose: YOLO11n-pose-golf (CoreML)")
        } else {
            pose = VisionPoseService()
            print("[CameraService] pose: Apple Vision (yolo11n-pose-golf unavailable)")
        }
        self.poseService = pose
        super.init()
        poseService.onPoseUpdate = { [weak self] pose in
            guard let self else { return }
            self.swingRecorder.append(pose)     // explicit-record path
            self.swingDetector.ingest(pose)     // legacy heuristic (kept for telemetry / fallback)
            self.liveTracker.ingest(pose)       // always-on Pose-TCN sliding-window tracker
        }
        // Detected a dark/backlit face → pull exposure up automatically. Uses a
        // global exposure-bias (no coordinate mapping), gated on a valid face.
        lighting.onResult = { [weak self] adv in
            guard let self, adv.faceBox != nil else { return }
            self.subjectFocus?.autoBrighten(faceLuma: adv.faceLuma)
        }
        // Primary live trigger: LiveSwingTracker (Pose-TCN real-time events).
        // Carries pre-decoded SwingEvents so SwingRecorder can skip its own detection pass.
        liveTracker.onSwingDetected = { [weak self] poses, _ in
            guard let self else { return }
            // Re-derive the SAVED events from the resampling PoseTCN detector
            // (events: nil → SwingRecorder runs eventDetector.detect on the
            // finalized buffer). The live tracker's real-time events came off a
            // dropped/irregular buffer and drift ~0.5 s; detect() interpolates to
            // uniform 30 fps first. Runs on emitQueue (background), once per swing.
            let (report, score) = self.swingRecorder.publish(
                autoDetectedPoses: poses, events: nil
            )
            // Hand the per-swing (report, score) straight to the live consumer
            // via the captured closure — survives back-to-back emits where the
            // @Observable swingRecorder.report slot would be overwritten.
            if let cb = self.onLiveSwing {
                DispatchQueue.main.async { cb(report, score) }
            }
        }
        // Fallback (heuristic) still wired but only logs — primary path is liveTracker.
        swingDetector.onSwingDetected = { _ in
            print("[CameraService] heuristic swing fired (fallback path, suppressed)")
        }
        // Upload path keeps using PoseTCNEventDetector via SwingRecorder.eventDetector.
        if let detector = try? PoseTCNEventDetector() {
            swingRecorder.eventDetector = detector
            print("[CameraService] event detector: Pose-TCN (CoreML)")
        } else {
            print("[CameraService] event detector: heuristic (Pose-TCN unavailable)")
        }
    }

    func bootstrap() async {
        #if targetEnvironment(simulator)
        startSimCamera()   // 模拟器：视频冒充摄像头，不走 AVCaptureSession
        return
        #else
        let videoOK = await Self.requestAccess(.video)
        guard videoOK else {
            await MainActor.run { self.state = .denied }
            return
        }
        configure()
        #endif
    }

    #if targetEnvironment(simulator)
    /// 模拟器虚拟摄像头：循环播放打包视频，每帧 → 姿态管线（驱动 liveTracker）
    /// + 发布 simFrame 当预览。和真机走同一套检测代码，只是帧源换成视频。
    func startSimCamera() {
        recordingSourceIsPortrait = true   // virtual-camera frames are already portrait
        simTask?.cancel()
        simTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runSimCameraLoop()
        }
    }

    private func runSimCameraLoop() async {
        // Source priority: SIMVIDEO=<name> in Documents/ (lets us point the
        // virtual camera at any real golf clip pushed into the container, no
        // rebuild) → bundled sim_camera.mp4 fallback.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var resolved: URL?
        if let name = ProcessInfo.processInfo.environment["SIMVIDEO"] {
            let candidate = docs.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                resolved = candidate
                print("[SimCam] using SIMVIDEO=\(name)")
            } else {
                print("[SimCam] SIMVIDEO=\(name) not found in Documents — falling back")
            }
        }
        if resolved == nil {
            resolved = Bundle.main.url(forResource: "sim_camera", withExtension: "mp4")
        }
        guard let url = resolved else {
            print("[SimCam] no virtual-camera video available")
            await MainActor.run { self.state = .ready }
            return
        }
        // Set videoSize to the clip's real dimensions BEFORE going .ready — that
        // transition triggers auto-start → openNewChunk, whose VideoRecorder must
        // be created at the right size (else clips come out scaled/distorted).
        let probe = AVURLAsset(url: url)
        if let track = try? await probe.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            self.videoSize = CGSize(width: abs(size.width), height: abs(size.height))
        }
        await MainActor.run { self.state = .ready }
        print("[SimCam] virtual camera start (\(url.lastPathComponent)) size=\(videoSize)")

        // Running offset that makes PTS monotonically increase ACROSS loops. The
        // source mp4 restarts at PTS 0 every loop; a real camera never rewinds,
        // and AVAssetWriter / the swing-range math both require a continuous
        // timeline, so we shift each loop's frames past the previous loop's end.
        var loopOffset = CMTime.zero
        while !Task.isCancelled {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let reader = try? AVAssetReader(asset: asset) else {
                print("[SimCam] asset/reader init failed"); return
            }
            let out = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            guard reader.canAdd(out) else { return }
            reader.add(out)
            guard reader.startReading() else {
                print("[SimCam] startReading failed: \(String(describing: reader.error))"); return
            }
            var loopEnd = loopOffset
            while let raw = out.copyNextSampleBuffer(), !Task.isCancelled {
                // Retime onto the continuous timeline.
                let origPTS = CMSampleBufferGetPresentationTimeStamp(raw)
                var dur = CMSampleBufferGetDuration(raw)
                if !dur.isValid || dur == .zero { dur = CMTime(value: 1, timescale: 30) }
                let newPTS = CMTimeAdd(origPTS, loopOffset)
                let buf = Self.retimed(raw, pts: newPTS, duration: dur) ?? raw
                loopEnd = CMTimeAdd(newPTS, dur)

                if let px = CMSampleBufferGetImageBuffer(buf) {
                    let ci = CIImage(cvPixelBuffer: px)
                    if let cg = simCIContext.createCGImage(ci, from: ci.extent) {
                        await MainActor.run { self.simFrame = cg }
                    }
                }
                // Drive the pose pipeline, the lighting detector, AND the session
                // recorder with the retimed buffer — exactly what captureOutput
                // does on a device. Lighting JUDGEMENT (backlit/dark/bright) runs
                // here on the real footage; the auto-brighten ACTUATION it would
                // trigger is device-only (no exposure control on a video file).
                var latest: PoseFrame?
                if inferenceEnabled, let pose = poseService.extractSync(buf, cgOrientation: .up) {
                    latest = pose
                    await MainActor.run { self.poseService.onPoseUpdate?(pose) }
                }
                if inferenceEnabled {
                    lighting.ingest(buf, pose: latest, position: position)
                }
                recordSessionVideoFrame(buf)
                try? await Task.sleep(for: .milliseconds(33))   // ~30fps
            }
            loopOffset = loopEnd   // next loop continues past this one
        }
    }

    /// Copy a sample buffer with new timing (shares the underlying image
    /// buffer). Used to put the looped virtual-camera frames on a continuous
    /// timeline.
    private static func retimed(_ buf: CMSampleBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: buf,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out)
        return status == noErr ? out : nil
    }
    #endif

    private static func requestAccess(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    private func configure() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.publish(.configuring)

            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1920x1080

            self.attachVideoInput(position: .back)
            // Intentionally NOT attaching mic input here. Claiming the mic
            // forces iOS to interrupt the user's music app, and tearing the
            // mic input down later can deadlock AVCaptureSession. We don't
            // need swing audio anyway — saved clips are silent.

            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            self.videoOutput.alwaysDiscardsLateVideoFrames = false
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }

            self.session.commitConfiguration()
            self.session.startRunning()
            self.publish(.ready)
        }
    }

    // MARK: - capture modes (multi-angle / cinematic)
    //
    // `.analysis` is the existing single-wide graph set up by `configure()` and
    // is NEVER touched by this machinery — the analysis path is safe by
    // construction. `.multiAngle` / `.cinematic` rebuild the session; the wide
    // stream is always wired to `videoOutput`, so pose → event → coaching →
    // archive keep running in EVERY mode. These two modes are DEVICE-ONLY (the
    // simulator's CaptureCapabilities reports only `.analysis`, so the switcher
    // hides them and this code never runs there) and STILL NEED REAL-DEVICE
    // VALIDATION — they structurally mirror the lab's device-tested
    // CaptureController (multicam wiring / cinematic format).

    /// User picked a capture mode in RecordView. No-op for the current mode or
    /// a mode this device can't run.
    func setCaptureMode(_ mode: CaptureMode) {
        guard mode != captureMode, captureCaps.availableModes.contains(mode) else { return }
        sessionQueue.async { [weak self] in self?.rebuildSession(for: mode) }
    }

    #if DEBUG
    /// Force a mode rebuild BYPASSING the capability gate. Lets the simulator
    /// verify the crash-safety path: requesting multi-angle where it can't be
    /// built (no multicam hardware in the sim) must fail GRACEFULLY — revert to
    /// analysis — not crash. Real multicam capture still needs a device.
    func debugForceMode(_ mode: CaptureMode) {
        sessionQueue.async { [weak self] in self?.rebuildSession(for: mode) }
    }
    #endif

    private func rebuildSession(for mode: CaptureMode) {
        let previous = captureMode
        if session.isRunning { session.stopRunning() }
        teleFocus = nil
        videoOutput = AVCaptureVideoDataOutput()   // fresh output for the new session
        let fresh: AVCaptureSession = (mode == .multiAngle) ? AVCaptureMultiCamSession() : AVCaptureSession()
        fresh.beginConfiguration()
        let ok: Bool
        switch mode {
        case .analysis:   ok = buildWideGraph(fresh)
        case .multiAngle: ok = buildMultiAngleGraph(fresh)
        case .cinematic:  ok = buildCinematicGraph(fresh)
        }
        fresh.commitConfiguration()
        guard ok else {
            dbg(.error, tag: "cam", "build \(mode.rawValue) failed — reverting to \(previous.rawValue)")
            if mode != .analysis { rebuildSession(for: .analysis) }
            return
        }
        session = fresh
        fresh.startRunning()
        Task { @MainActor in self.captureMode = mode; self.telePreview = nil }
        dbg(tag: "cam", "capture mode = \(mode.rawValue)")
    }

    private func configureWideOutput() {
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = false
    }

    /// Single wide camera → videoOutput (pose/lighting/record) + focus. Mirrors
    /// `configure()` on a passed-in session — used when switching BACK to
    /// analysis from another mode.
    @discardableResult
    private func buildWideGraph(_ s: AVCaptureSession) -> Bool {
        s.sessionPreset = .hd1920x1080
        guard let device = bestCamera(position: .back),
              let input = try? AVCaptureDeviceInput(device: device), s.canAddInput(input) else { return false }
        s.addInput(input); videoInput = input
        configureFrameRate(device: device, fps: 30)
        configureWideOutput()
        guard s.canAddOutput(videoOutput) else { return false }
        s.addOutput(videoOutput)
        enableIntrinsicsDelivery()
        subjectFocus = SubjectFocusController(device: device, position: .back, queue: sessionQueue)
        return true
    }

    /// Ask AVFoundation to attach the camera intrinsic matrix to each sample
    /// buffer (device-only capability). First frame that carries it gets
    /// persisted once per run — the 3D ball-trajectory pipeline needs fx/fy/
    /// cx/cy to backproject 2D detections.
    private func enableIntrinsicsDelivery() {
        guard let conn = videoOutput.connection(with: .video),
              conn.isCameraIntrinsicMatrixDeliverySupported else { return }
        conn.isCameraIntrinsicMatrixDeliveryEnabled = true
    }

    /// Persist intrinsics from the first carrying sample buffer to
    /// Documents/camera_intrinsics_latest.json (row-major 3×3 + buffer dims).
    /// Frames to skip between pose inferences, by thermal pressure. 1 = every
    /// frame (30 fps). Rises under heat to throttle our own ANE contribution so
    /// the phone can shed heat without the OS throttling the whole pipeline.
    private static func poseStride() -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: return 3   // ~10 fps
        case .serious:  return 2   // ~15 fps
        default:        return 1   // 30 fps (nominal / fair)
        }
    }

    private func persistIntrinsicsOnce(_ sampleBuffer: CMSampleBuffer) {
        guard !didPersistIntrinsics,
              let att = CMGetAttachment(sampleBuffer,
                                        key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                        attachmentModeOut: nil) as? Data else { return }
        didPersistIntrinsics = true
        let m: matrix_float3x3 = att.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
        var dims = (w: 0, h: 0)
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            dims = (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
        }
        let obj: [String: Any] = [
            "fx": m.columns.0.x, "fy": m.columns.1.y,
            "cx": m.columns.2.x, "cy": m.columns.2.y,
            "width": dims.w, "height": dims.h,
            "note": "AVCaptureConnection cameraIntrinsicMatrix, buffer pixel coords",
        ]
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? data.write(to: docs.appendingPathComponent("camera_intrinsics_latest.json"), options: .atomic)
            dbg(tag: "cam", "intrinsics persisted fx=\(m.columns.0.x) fy=\(m.columns.1.y)")
        }
        appendGravityToIntrinsics(obj)
    }

    /// One-shot CoreMotion gravity sample appended to the intrinsics JSON —
    /// the extrinsic half the 3D ball solver needs (camera-frame gravity dir).
    private let motionManager = CMMotionManager()
    /// Dedicated background queue for CoreMotion delivery. Delivering to `.main`
    /// per swing floods the main thread with 20 Hz callbacks (+ a main-thread
    /// file write) and freezes the UI after a couple of swings.
    private let motionQueue = OperationQueue()
    private func appendGravityToIntrinsics(_ base: [String: Any]) {
        // Don't (re)start while a previous one-shot is still running — restarting
        // per swing without stopping leaks 20 Hz update streams.
        guard motionManager.isDeviceMotionAvailable,
              !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 0.05
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            self.motionManager.stopDeviceMotionUpdates()
            var obj = base
            // CoreMotion gravity is in DEVICE coords (x right, y up, z out of
            // screen); camera coords flip y and z. Portrait back camera:
            obj["gravity"] = [g.x, -g.y, -g.z]
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
                try? data.write(to: docs.appendingPathComponent("camera_intrinsics_latest.json"), options: .atomic)
                dbg(tag: "cam", "gravity persisted \(obj["gravity"] ?? "")")
            }
        }
    }

    /// MultiCam: wide (analysis, identical to `.analysis`) + telephoto (sharp
    /// optical close-up → teleOutput for PiP preview). DEVICE-ONLY.
    private func buildMultiAngleGraph(_ s: AVCaptureSession) -> Bool {
        // Use the PHYSICAL wide + tele lenses — NOT bestCamera (which returns a
        // virtual triple/dual-cam device that can't be paired with the tele in a
        // MultiCamSession → the immediate crash on the first multi-angle tap).
        guard let multi = s as? AVCaptureMultiCamSession, AVCaptureMultiCamSession.isMultiCamSupported,
              let wide = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .back).devices.first,
              let tele = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInTelephotoCamera], mediaType: .video, position: .back).devices.first
        else { return false }
        // Apple-recommended guard: only build if THIS exact wide+tele pair is a
        // supported simultaneous set. The crash came from feeding an unsupported
        // combo (virtual triple-cam + tele) to AVFoundation; validating up front
        // means an unsupported device just bails (→ revert to analysis), never
        // crashes.
        let ds = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .back)
        guard ds.supportedMultiCamDeviceSets.contains(where: { $0.contains(wide) && $0.contains(tele) }) else {
            dbg(.warn, tag: "cam", "wide+tele not a supported multicam set — bailing to analysis")
            return false
        }
        setMultiCamFormat(wide); setMultiCamFormat(tele)
        configureWideOutput()
        teleOutput.setSampleBufferDelegate(self, queue: videoQueue)
        teleOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        teleOutput.alwaysDiscardsLateVideoFrames = true
        guard wireMultiCam(multi, device: wide, output: videoOutput),
              wireMultiCam(multi, device: tele, output: teleOutput) else { return false }
        // ISP hard limit: cost > 1 makes startRunning fail/throw. Bail (→ revert
        // to analysis) rather than crash if this device set is too heavy at 1080p.
        guard multi.hardwareCost <= 1.0 else {
            dbg(.warn, tag: "cam", "multicam hardwareCost \(multi.hardwareCost) > 1 — bailing")
            return false
        }
        subjectFocus = SubjectFocusController(device: wide, position: .back, queue: sessionQueue)
        teleFocus = SubjectFocusController(device: tele, position: .back, queue: sessionQueue)
        return true
    }

    /// Cinematic: single camera with computational shallow depth-of-field; the
    /// subject stays sharp so pose still runs. iOS 26+. DEVICE-ONLY.
    private func buildCinematicGraph(_ s: AVCaptureSession) -> Bool {
        guard #available(iOS 26.0, *),
              let dev = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInDualWideCamera, .builtInWideAngleCamera],
                mediaType: .video, position: .back).devices.first,
              let fmt = dev.formats.last(where: { $0.isCinematicVideoCaptureSupported })
        else { return false }
        do { try dev.lockForConfiguration(); dev.activeFormat = fmt; dev.unlockForConfiguration() }
        catch { return false }
        guard let input = try? AVCaptureDeviceInput(device: dev), s.canAddInput(input),
              input.isCinematicVideoCaptureSupported else { return false }
        input.isCinematicVideoCaptureEnabled = true
        s.addInput(input); videoInput = input
        configureWideOutput()
        guard s.canAddOutput(videoOutput) else { return false }
        s.addOutput(videoOutput)
        subjectFocus = SubjectFocusController(device: dev, position: .back, queue: sessionQueue)
        return true
    }

    private func wireMultiCam(_ s: AVCaptureMultiCamSession, device: AVCaptureDevice,
                              output: AVCaptureVideoDataOutput) -> Bool {
        guard let input = try? AVCaptureDeviceInput(device: device), s.canAddInput(input) else { return false }
        s.addInputWithNoConnections(input)
        guard s.canAddOutput(output) else { return false }
        s.addOutputWithNoConnections(output)
        guard let port = input.ports(for: .video, sourceDeviceType: device.deviceType,
                                     sourceDevicePosition: device.position).first else { return false }
        let conn = AVCaptureConnection(inputPorts: [port], output: output)
        guard s.canAddConnection(conn) else { return false }
        s.addConnection(conn)
        return true
    }

    private func setMultiCamFormat(_ device: AVCaptureDevice) {
        let mc = device.formats.filter { $0.isMultiCamSupported }
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        }
        let pick = mc.first { dims($0).width == 1920 && dims($0).height == 1080 } ?? mc.first
        guard let fmt = pick, (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = fmt
        device.unlockForConfiguration()
    }

    /// Stop the capture session entirely — used by PowerBench's idle mode
    /// to measure baseline drain (no camera, no inference).
    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }
    /// Resume the capture session after a previous stopSession.
    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if let cur = self.videoInput { self.session.removeInput(cur) }
            let next: AVCaptureDevice.Position = (self.position == .back) ? .front : .back
            self.attachVideoInput(position: next)
            self.session.commitConfiguration()
            let resolved: CameraPosition = (next == .back) ? .back : .front
            DispatchQueue.main.async {
                self.position = resolved
            }
        }
    }

    private func attachVideoInput(position: AVCaptureDevice.Position) {
        guard let device = bestCamera(position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            publish(.error("No camera available for position \(position.rawValue)"))
            return
        }
        session.addInput(input)
        videoInput = input
        // 30 fps capture is plenty for pose + swing-event work and meaningfully
        // cooler / cheaper than 60 fps (less ISP work, half the buffer copies).
        // Bump back to 60 only if we ever need slow-mo for ball/club tracking.
        configureFrameRate(device: device, fps: 30)
        // Face-driven auto-brighten lives on this device (recreated on camera
        // switch). Only its global exposure-bias path is used in the live flow.
        let camPos: CameraPosition = position == .front ? .front : .back
        subjectFocus = SubjectFocusController(device: device, position: camPos, queue: sessionQueue)
    }

    private func attachAudioInput() {
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        audioInput = input
    }

    private func bestCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInWideAngleCamera,
        ]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: position
        )
        return session.devices.first
    }

    private func configureFrameRate(device: AVCaptureDevice, fps: Int32) {
        let target = device.formats.first { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let supports1080 = dims.width == 1920 && dims.height == 1080
            let supportsFps = format.videoSupportedFrameRateRanges.contains {
                Int32($0.maxFrameRate) >= fps
            }
            return supports1080 && supportsFps
        }
        guard let format = target else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: fps)
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
            videoSize = CGSize(width: 1920, height: 1080)
        } catch {
            publish(.error("Frame rate config failed: \(error.localizedDescription)"))
        }
    }

    func startRecording() {
        // Re-snapshot intrinsics + gravity for THIS shot: a range session is
        // dozens of swings and the phone gets repositioned between them — a
        // session-start gravity sample goes stale and tilts the ball solver.
        didPersistIntrinsics = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let url = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("swing_\(Int(Date().timeIntervalSince1970)).mp4")
            do {
                let rec = try VideoRecorder(outputURL: url, sensorSize: self.videoSize, isFrontCamera: self.position == .front)
                rec.start()
                self.recorderLock.lock()
                self.recorder = rec
                self.recorderLock.unlock()
                DispatchQueue.main.async { self.swingRecorder.start() }
                self.publish(.recording)
            } catch {
                self.publish(.error("Recorder start failed: \(error.localizedDescription)"))
            }
        }
    }

    func stopRecording() async {
        let rec: VideoRecorder?
        recorderLock.lock()
        rec = recorder
        recorder = nil
        recorderLock.unlock()
        guard let rec else { return }
        let url = await rec.finish()
        swingRecorder.stop(recordingURL: url)
        await MainActor.run {
            self.lastRecordingURL = url
            self.state = .ready
        }
    }

    // MARK: - session recording (chunked)

    /// Defensive resync before a new session starts. Belt-and-braces
    /// cleanup of every piece of state that can outlive a session and
    /// silently poison the next one:
    ///   - Pose service's `isProcessing` guard — if the prior inference
    ///     didn't fire its cleanup defer (background suspend, model
    ///     stall), every subsequent frame is dropped at the lock check.
    ///   - LiveSwingTracker buffer + `lastInferAt` — handled inside its
    ///     own `reset()`, but called here so the caller doesn't have to.
    ///   - AVCaptureSession running state — if iOS suspended it during
    ///     backgrounding and didn't auto-resume, `startRunning()` here
    ///     is the only path back to live frames.
    func resetForNewSession() {
        poseService.forceClearBusy()
        liveTracker.reset()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning {
                dbg(.warn, tag: "cam", "AVCaptureSession not running — restarting")
                self.session.startRunning()
            }
        }
    }

    /// Start chunked session recording. First chunk opens immediately;
    /// captureOutput rolls subsequent chunks over every
    /// `chunkDurationSeconds`.
    func startSessionRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.sessionRecorderLock.lock()
            if self.currentChunkRecorder != nil { self.sessionRecorderLock.unlock(); return }
            self.sessionRecorderLock.unlock()
            self.sessionRecordingStartedAt = Date()
            self.openNewChunk()
        }
    }

    /// Open the next chunk in the chain. Called from `startSessionRecording`
    /// and from `swapChunk`.
    private func openNewChunk() {
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("session_\(Int(Date().timeIntervalSince1970 * 1000)).mp4")
        do {
            let rec = try VideoRecorder(
                outputURL: url, sensorSize: self.videoSize,
                isFrontCamera: self.position == .front,
                overrideTransform: recordingSourceIsPortrait ? .identity : nil)
            rec.start()
            sessionRecorderLock.lock()
            currentChunkRecorder = rec
            currentChunkURL = url
            currentChunkFirstPTSSeconds = nil
            currentChunkStartedAt = Date()
            chunkSwapInFlight = false
            sessionRecorderLock.unlock()
            dbg(tag: "cam", "chunk OPEN \(url.lastPathComponent)")
        } catch {
            sessionRecorderLock.lock()
            chunkSwapInFlight = false
            sessionRecorderLock.unlock()
            dbg(.error, tag: "cam", "chunk OPEN failed: \(error.localizedDescription)")
        }
    }

    /// Append one video frame to the active session chunk: set the chunk's
    /// time origin from the first frame's PTS, append, and roll over to a new
    /// chunk every `chunkDurationSeconds` once the swing tracker is idle.
    /// Called from `captureOutput` (real camera) AND from `runSimCameraLoop`
    /// (the simulator's virtual camera), so both record identically.
    private func recordSessionVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        sessionRecorderLock.lock()
        let chunkRec = currentChunkRecorder
        let chunkStartedAt = currentChunkStartedAt
        let swapInFlight = chunkSwapInFlight
        let chunkURL = currentChunkURL
        sessionRecorderLock.unlock()
        guard let chunkRec else { return }
        // First-frame PTS becomes the chunk's time origin
        // (AVAssetWriter.startSession(atSourceTime:)). Per-swing clip ranges
        // are computed relative to it.
        if currentChunkFirstPTSSeconds == nil {
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            if pts.isFinite {
                sessionRecorderLock.lock()
                if currentChunkFirstPTSSeconds == nil { currentChunkFirstPTSSeconds = pts }
                sessionRecorderLock.unlock()
            }
        }
        chunkRec.appendVideo(sampleBuffer)
        // Chunk rollover — only when the tracker is idle, so a swing is never
        // split across a chunk boundary. Two triggers:
        //   1. past `chunkDurationSeconds` (the steady-state cadence), or
        //   2. this chunk already has a swing clip QUEUED — roll now so the mp4
        //      lands seconds after the swing (in-session replay reads it).
        // (2) must check the archive: rolling before the clip is queued would
        // make `onChunkClosed` export nothing and then delete the chunk = the
        // swing's video is lost for good.
        let elapsed = chunkStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let earlyRoll = elapsed >= minChunkSecondsBeforeEarlyRoll
            && chunkURL.map { chunkHasQueuedClips?($0) ?? false } ?? false
        if !swapInFlight,
           chunkStartedAt != nil,
           elapsed >= chunkDurationSeconds || earlyRoll,
           liveTracker.state == .idle
        {
            sessionRecorderLock.lock()
            let shouldSwap = !chunkSwapInFlight
            if shouldSwap { chunkSwapInFlight = true }
            sessionRecorderLock.unlock()
            if shouldSwap { swapChunk() }
        }
    }

    /// Swap the current chunk for a fresh one. Old chunk finalizes
    /// asynchronously; once its mp4 is fully written, fires `onChunkClosed`
    /// so SwingArchive can drain that chunk's per-swing clips. Open the
    /// new chunk FIRST so there's no recording gap.
    private func swapChunk() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.sessionRecorderLock.lock()
            guard let oldRec = self.currentChunkRecorder,
                  let oldURL = self.currentChunkURL else {
                self.chunkSwapInFlight = false
                self.sessionRecorderLock.unlock()
                return
            }
            self.sessionRecorderLock.unlock()
            dbg(tag: "cam", "chunk SWAP begin (old=\(oldURL.lastPathComponent))")
            self.openNewChunk()
            Task { [weak self] in
                let finalURL = await oldRec.finish()
                dbg(tag: "cam", "chunk SWAP done (closed=\(finalURL.lastPathComponent))")
                self?.onChunkClosed?(oldURL)
            }
        }
    }

    /// Finalize the LAST chunk on session end. Backstop drainer in
    /// SwingArchive picks up any remaining clips from this chunk.
    /// Clears every piece of chunk-cycle state so the next
    /// `startSessionRecording` opens a fresh chunk instead of bailing on
    /// the early-return guard.
    func stopSessionRecording() async -> URL? {
        sessionRecorderLock.lock()
        let rec = currentChunkRecorder
        let url = currentChunkURL
        currentChunkRecorder = nil
        currentChunkURL = nil
        currentChunkFirstPTSSeconds = nil
        currentChunkStartedAt = nil
        sessionRecordingStartedAt = nil
        chunkSwapInFlight = false
        sessionRecorderLock.unlock()
        guard let rec else { return nil }
        let final = await rec.finish()
        print("[CameraService] last chunk finished → \(final.lastPathComponent)")
        // NB: do NOT fire `onChunkClosed` here. That drain is async + fire-and-
        // forget, so it would race `SessionLifecycle.end()`'s explicit
        // `processPendingClips()` for this same final chunk — and onChunkClosed
        // deletes the chunk file at the end, which could delete it out from
        // under processPendingClips mid-export → a swing with no video. The
        // final chunk is drained (and deleted) solely by processPendingClips,
        // which end() awaits right after this returns. Mid-session chunk
        // rotations still use onChunkClosed (no concurrent drain there).
        return url ?? final
    }

    private func publish(_ s: State) {
        DispatchQueue.main.async { self.state = s }
    }

    /// Telephoto PiP preview (multi-angle). ~15 fps is plenty for a thumbnail.
    private func publishTelePreview(_ sampleBuffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        if now - lastTelePreviewAt < 0.066 { return }
        lastTelePreviewAt = now
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: px).oriented(.right)
        guard let cg = previewCIContext.createCGImage(ci, from: ci.extent) else { return }
        DispatchQueue.main.async { self.telePreview = cg }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Telephoto stream (multi-angle only): publish as PiP preview. The wide
        // stream below still drives ALL pose/coaching/recording.
        if output === teleOutput {
            publishTelePreview(sampleBuffer)
            return
        }
        if output === videoOutput {
            persistIntrinsicsOnce(sampleBuffer)
            // Always run pose at 30 fps. The previous throttle was keyed on
            // `liveTracker.state != .idle`, but the Finish-only state
            // machine sits in `.idle` for the ENTIRE swing — pose ended up
            // sampled at 7.5 fps, and PoseTCN (trained on 30 fps) produced
            // events off by ~0.5 s, so the saved clip's phase markers
            // didn't line up with what the body was actually doing.
            // YOLO11n-pose on ANE + PoseTCN at stride 8 is well under
            // 100 mW so the steady-state cost is fine.
            frameCounter &+= 1
            // Thermal-adaptive pose rate: sustained range use heats the phone;
            // as thermalState rises we skip pose frames so we stop feeding the
            // fire (our ANE load), letting the recording (the user's actual
            // deliverable) stay smooth and the phone recover. Event segmentation
            // is resample-robust to the lower live rate, and History swings are
            // re-analysed densely off the saved clip anyway.
            if inferenceEnabled, frameCounter % Int64(Self.poseStride()) == 0 {
                poseService.submit(sampleBuffer, orientation: .from(position))
                // Face-exposure check (throttled ~3 Hz internally) → drives the
                // auto-brighten via lighting.onResult. Reads the latest pose for
                // the face box; cheap 32×24 luma render.
                lighting.ingest(sampleBuffer, pose: poseService.latestPose, position: position)
            }
        }

        // Per-take recorder (manual Record button path).
        recorderLock.lock()
        let rec = recorder
        recorderLock.unlock()
        if let rec {
            if output === videoOutput { rec.appendVideo(sampleBuffer) }
            else if output === audioOutput { rec.appendAudio(sampleBuffer) }
        }

        // Chunked session recorder. Factored out so the simulator's virtual
        // camera can drive the SAME recording path (see runSimCameraLoop).
        if output === videoOutput {
            recordSessionVideoFrame(sampleBuffer)
        } else if output === audioOutput {
            sessionRecorderLock.lock()
            let chunkRec = currentChunkRecorder
            sessionRecorderLock.unlock()
            chunkRec?.appendAudio(sampleBuffer)
        }
    }
}
