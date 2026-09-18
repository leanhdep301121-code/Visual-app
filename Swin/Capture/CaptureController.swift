import AVFoundation
import CoreImage
import Foundation
import Observation
import UIKit

/// The capture engine for the new capture-rig features. Owns ONE session at a
/// time (`AVCaptureSession` for analysis/cinematic, `AVCaptureMultiCamSession`
/// for multi-angle — the latter is a subclass, so the var holds either) and
/// rebuilds it when the mode changes (MultiCam ⇄ Cinematic can't coexist).
///
/// Wiring per mode:
///   - `.analysis`  : wide → pose + LightingAdvisor + SubjectFocus (+ optional record)
///   - `.multiAngle`: wide (pose/lighting/focus) + tele (sharp close-up); both record
///   - `.cinematic` : wide with bokeh baked in → pose still runs (subject sharp);
///                    metadata → CinematicController racks focus onto the golfer
///
/// Preview is published as a `CGImage` decoded from the wide stream — uniform
/// across modes and avoids per-mode preview-connection plumbing.
@Observable
final class CaptureController: NSObject, @unchecked Sendable {
    // UI-facing
    private(set) var mode: CaptureMode = .analysis
    private(set) var previewImage: CGImage?       // wide stream
    private(set) var telePreviewImage: CGImage?   // tele stream (multi-angle only)
    let lighting = LightingAdvisor()
    let capabilities = CaptureCapabilities.detect()
    /// Cinematic bokeh aperture, mirrored for the UI slider (0 when not cinematic).
    private(set) var cinematicAperture: Float = 0
    private(set) var cinematicRange: ClosedRange<Float> = 1...16

    // session + queues
    @ObservationIgnored private(set) var session: AVCaptureSession = AVCaptureSession()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "com.swin.capturectl.session")
    @ObservationIgnored private let sampleQueue = DispatchQueue(label: "com.swin.capturectl.sample", qos: .userInitiated)
    @ObservationIgnored private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    @ObservationIgnored private var lastPreviewAt: CFTimeInterval = 0
    @ObservationIgnored private var lastTelePreviewAt: CFTimeInterval = 0

    // pose + leaf controllers
    @ObservationIgnored private let pose: PoseService?
    @ObservationIgnored private var wideFocus: SubjectFocusController?
    @ObservationIgnored private var teleFocus: SubjectFocusController?
    @ObservationIgnored private var cinematic: AnyObject?   // CinematicController (iOS 26)

    // outputs
    @ObservationIgnored private var wideOut = AVCaptureVideoDataOutput()
    @ObservationIgnored private var teleOut = AVCaptureVideoDataOutput()
    @ObservationIgnored private let metaOut = AVCaptureMetadataOutput()

    // recording — dynamic save via rolling keepers (one per stream)
    private(set) var isRolling = false
    private(set) var keptCount = 0
    @ObservationIgnored private let recLock = NSLock()
    @ObservationIgnored private var wideKeeper: RollingClipKeeper?
    @ObservationIgnored private var teleKeeper: RollingClipKeeper?

    override init() {
        self.pose = try? YoloPoseService()
        super.init()
        pose?.onPoseUpdate = { [weak self] frame in
            self?.wideFocus?.update(pose: frame)
        }
        // Detected a dark/backlit face → pull exposure up automatically.
        lighting.onResult = { [weak self] adv in
            guard let self, adv.faceBox != nil else { return }
            self.wideFocus?.autoBrighten(faceLuma: adv.faceLuma)
        }
    }

    // MARK: - lifecycle

    func start(mode: CaptureMode) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let granted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            guard granted else {
                Task { _ = await AVCaptureDevice.requestAccess(for: .video); self.start(mode: mode) }
                return
            }
            self.reconfigure(to: mode)
        }
    }

    func switchMode(_ mode: CaptureMode) {
        sessionQueue.async { [weak self] in self?.reconfigure(to: mode) }
    }

    func stop() {
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
    }

    private func reconfigure(to newMode: CaptureMode) {
        if session.isRunning { session.stopRunning() }
        wideFocus = nil; teleFocus = nil; cinematic = nil

        let fresh: AVCaptureSession = (newMode == .multiAngle) ? AVCaptureMultiCamSession() : AVCaptureSession()
        wideOut = AVCaptureVideoDataOutput()
        teleOut = AVCaptureVideoDataOutput()

        fresh.beginConfiguration()
        let ok: Bool
        switch newMode {
        case .analysis:   ok = buildAnalysis(fresh)
        case .multiAngle: ok = buildMultiAngle(fresh)
        case .cinematic:  ok = buildCinematic(fresh)
        }
        fresh.commitConfiguration()
        guard ok else { dbg(.error, tag: "capture", "build \(newMode.rawValue) failed"); return }

        session = fresh
        fresh.startRunning()
        DispatchQueue.main.async { self.mode = newMode; self.telePreviewImage = nil }
        dbg(tag: "capture", "mode=\(newMode.rawValue) running")
    }

    // MARK: - graph builders

    private func buildAnalysis(_ s: AVCaptureSession) -> Bool {
        s.sessionPreset = .hd1920x1080
        guard let wide = camera(.builtInWideAngleCamera, .back),
              let input = try? AVCaptureDeviceInput(device: wide),
              s.canAddInput(input) else { return false }
        s.addInput(input)
        configureWideOutput()
        guard s.canAddOutput(wideOut) else { return false }
        s.addOutput(wideOut)
        wideFocus = SubjectFocusController(device: wide, position: .back, queue: sessionQueue)
        return true
    }

    private func buildMultiAngle(_ s: AVCaptureSession) -> Bool {
        guard let multi = s as? AVCaptureMultiCamSession, AVCaptureMultiCamSession.isMultiCamSupported,
              let wide = camera(.builtInWideAngleCamera, .back),
              let tele = camera(.builtInTelephotoCamera, .back) else { return false }
        setMultiCamFormat(wide); setMultiCamFormat(tele)
        configureWideOutput()
        teleOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        teleOut.alwaysDiscardsLateVideoFrames = true
        teleOut.setSampleBufferDelegate(self, queue: sampleQueue)
        guard wireMultiCam(multi, device: wide, output: wideOut),
              wireMultiCam(multi, device: tele, output: teleOut) else { return false }
        wideFocus = SubjectFocusController(device: wide, position: .back, queue: sessionQueue)
        teleFocus = SubjectFocusController(device: tele, position: .back, queue: sessionQueue)
        return true
    }

    private func buildCinematic(_ s: AVCaptureSession) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard let dev = camera(.builtInDualWideCamera, .back) ?? camera(.builtInWideAngleCamera, .back),
              let fmt = CinematicController.cinematicFormat(for: dev) else { return false }
        do {
            try dev.lockForConfiguration(); dev.activeFormat = fmt; dev.unlockForConfiguration()
        } catch { return false }
        guard let input = try? AVCaptureDeviceInput(device: dev), s.canAddInput(input) else { return false }
        guard input.isCinematicVideoCaptureSupported else { return false }
        input.isCinematicVideoCaptureEnabled = true
        s.addInput(input)

        configureWideOutput()
        guard s.canAddOutput(wideOut) else { return false }
        s.addOutput(wideOut)

        if s.canAddOutput(metaOut) {
            s.addOutput(metaOut)
            metaOut.metadataObjectTypes = CinematicController.requiredMetadataTypes(metaOut)
            metaOut.setMetadataObjectsDelegate(self, queue: sampleQueue)
        }
        if let cc = CinematicController(device: dev, input: input, queue: sessionQueue) {
            cinematic = cc
            DispatchQueue.main.async {
                self.cinematicRange = cc.minAperture...cc.maxAperture
                self.cinematicAperture = cc.aperture
            }
        }
        return true
    }

    // MARK: - output / wiring helpers

    private func configureWideOutput() {
        wideOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        wideOut.alwaysDiscardsLateVideoFrames = true
        wideOut.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    private func wireMultiCam(_ s: AVCaptureMultiCamSession, device: AVCaptureDevice, output: AVCaptureVideoDataOutput) -> Bool {
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
        let multicam = device.formats.filter { $0.isMultiCamSupported }
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions { CMVideoFormatDescriptionGetDimensions(f.formatDescription) }
        let pick = multicam.first { dims($0).width == 1920 && dims($0).height == 1080 }
            ?? multicam.filter { dims($0).width <= 1920 && dims($0).height <= 1080 }
                .max { Int(dims($0).width) * Int(dims($0).height) < Int(dims($1).width) * Int(dims($1).height) }
            ?? multicam.first
        guard let fmt = pick, (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = fmt
        device.unlockForConfiguration()
    }

    private func camera(_ type: AVCaptureDevice.DeviceType, _ pos: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [type], mediaType: .video, position: pos).devices.first
    }

    // MARK: - recording

    /// Start/stop the rolling capture (continuous record into short chunks,
    /// only persisted on a keep signal — see `keepRecent`).
    func toggleRolling() {
        recLock.lock(); let on = wideKeeper != nil; recLock.unlock()
        on ? stopRolling() : startRolling()
    }

    private func startRolling() {
        let size = CGSize(width: 1920, height: 1080)
        let wk = RollingClipKeeper(label: "wide", sensorSize: size, isFront: false)
        wk.start()
        var tk: RollingClipKeeper?
        if mode == .multiAngle {
            tk = RollingClipKeeper(label: "tele", sensorSize: size, isFront: false)
            tk?.start()
        }
        recLock.lock(); wideKeeper = wk; teleKeeper = tk; recLock.unlock()
        DispatchQueue.main.async { self.isRolling = true }
    }

    private func stopRolling() {
        recLock.lock(); let wk = wideKeeper, tk = teleKeeper; wideKeeper = nil; teleKeeper = nil; recLock.unlock()
        wk?.stop(); tk?.stop()
        DispatchQueue.main.async { self.isRolling = false }
    }

    /// Persist the swing that just finished (high score, or a user "save this")
    /// across every rolling stream. Wired to a button in the lab; in production
    /// this is driven by SwingScore / gesture / voice.
    func keepRecent() {
        recLock.lock(); let wk = wideKeeper, tk = teleKeeper; recLock.unlock()
        guard wk != nil else { return }
        wk?.keepRecent(); tk?.keepRecent()
        DispatchQueue.main.async { self.keptCount += 1 }
    }

    // MARK: - cinematic aperture (UI)

    func setCinematicAperture(_ f: Float) {
        if #available(iOS 26.0, *), let cc = cinematic as? CinematicController {
            cc.setAperture(f)
            DispatchQueue.main.async { self.cinematicAperture = f }
        }
    }

    // MARK: - swing-driven focus lock (hook for LiveSwingTracker integration)

    func lockFocusForSwing() { wideFocus?.lockForSwing(); teleFocus?.lockForSwing() }
    func unlockFocus() { wideFocus?.unlock(); teleFocus?.unlock() }
}

// MARK: - frame + metadata delegates

extension CaptureController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === wideOut {
            // pose (async, drop-if-busy) drives focus via onPoseUpdate; lighting
            // reads the most recent pose alongside this frame.
            pose?.submit(sampleBuffer, orientation: .backPortrait)
            lighting.ingest(sampleBuffer, pose: pose?.latestPose, position: .back)
            publishPreview(sampleBuffer)
            recLock.lock(); let wk = wideKeeper; recLock.unlock()
            wk?.append(sampleBuffer)
        } else if output === teleOut {
            publishTelePreview(sampleBuffer)
            recLock.lock(); let tk = teleKeeper; recLock.unlock()
            tk?.append(sampleBuffer)
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        if #available(iOS 26.0, *), let cc = cinematic as? CinematicController {
            cc.onMetadata(metadataObjects)
        }
    }

    private func publishPreview(_ sampleBuffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        if now - lastPreviewAt < 0.05 { return }   // ~20 fps preview
        lastPreviewAt = now
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: px).oriented(.right)   // sensor landscape → portrait
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        DispatchQueue.main.async { self.previewImage = cg }
    }

    private func publishTelePreview(_ sampleBuffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        if now - lastTelePreviewAt < 0.066 { return }   // ~15 fps PiP is plenty
        lastTelePreviewAt = now
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: px).oriented(.right)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        DispatchQueue.main.async { self.telePreviewImage = cg }
    }
}
