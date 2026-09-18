import AVFoundation
import Foundation

/// On-device feasibility + cost PoC for **concurrent wide + telephoto capture**
/// (挥杆广角 + 特写长焦 并发) — the single biggest unknown for the capture-rig
/// plan. Gated behind env `MULTICAM=1` (DEBUG) so it never touches the normal
/// app flow. See `SwinApp.init`.
///
/// What it answers, all on real silicon (the simulator has no cameras):
///   1. Does an `AVCaptureMultiCamSession` with back wide + back tele actually
///      run on THIS phone? (tele = Pro-only)
///   2. `hardwareCost` / `systemPressureCost` — the ISP budget headroom
///      (must stay < 1.0; ≥ 1.0 = config rejected).
///   3. Do BOTH streams really deliver frames, and at what fps?
///   4. How fast does thermal state climb under the dual stream?
///
/// It runs its OWN short-lived session for ~10 s, prints to the Xcode console,
/// then tears down. It does NOT record or run inference — pure feasibility.
final class MultiCamProbe: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    private static var live: MultiCamProbe?   // keep alive for the run

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["MULTICAM"] == "1" else { return }
        let probe = MultiCamProbe()
        live = probe
        probe.start()
    }

    private let session = AVCaptureMultiCamSession()
    private let sampleQueue = DispatchQueue(label: "com.swin.multicamprobe", qos: .userInitiated)
    private let videoOutWide = AVCaptureVideoDataOutput()
    private let videoOutTele = AVCaptureVideoDataOutput()

    private let lock = NSLock()
    private var wideFrames = 0
    private var teleFrames = 0
    private var startedAt: Date?

    private func start() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ok = await AVCaptureDevice.requestAccess(for: .video)
            guard ok else { line("camera denied — abort"); return }
            self.configureAndRun()
        }
    }

    private func configureAndRun() {
        line("──────── multicam PoC ────────")
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            line("multicam NOT supported on this device — abort"); return
        }
        guard let wide = camera(.builtInWideAngleCamera) else {
            line("no back wide camera — abort"); return
        }
        guard let tele = camera(.builtInTelephotoCamera) else {
            line("no back TELEPHOTO camera (non-Pro?) — abort. 广角+长焦特写需 Pro 机型"); return
        }

        session.beginConfiguration()

        // Pick a multicam-capable format per camera, preferring 1080p (the
        // analysis res) — not the lowest available, which is too coarse for pose.
        setMultiCamFormat(on: wide, label: "wide")
        setMultiCamFormat(on: tele, label: "tele")

        guard wire(device: wide, output: videoOutWide, label: "wide"),
              wire(device: tele, output: videoOutTele, label: "tele") else {
            session.commitConfiguration()
            line("failed to wire one of the streams — abort"); return
        }

        // hardwareCost is meaningful once inputs/outputs/connections are in place.
        line(String(format: "hardwareCost=%.3f  systemPressureCost=%.3f  (hardwareCost must be < 1.0)",
                    session.hardwareCost, session.systemPressureCost))
        if session.hardwareCost >= 1.0 {
            line("⚠️ hardwareCost ≥ 1.0 — would be rejected. 需降分辨率/选 binned 格式")
        }

        // MUST commit before startRunning — startRunning between begin/commit throws.
        session.commitConfiguration()

        let thermalBefore = thermalName(ProcessInfo.processInfo.thermalState)
        startedAt = Date()
        session.startRunning()
        line("session started · thermal=\(thermalBefore) · sampling 10s…")

        // Sample for 10 s, report per-stream fps + thermal drift, then tear down.
        sampleQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            line(String(format: "while running: hardwareCost=%.3f  systemPressureCost=%.3f",
                        self.session.hardwareCost, self.session.systemPressureCost))
            self.session.stopRunning()
            self.lock.lock()
            let w = self.wideFrames, t = self.teleFrames
            self.lock.unlock()
            let secs = Date().timeIntervalSince(self.startedAt ?? Date())
            line(String(format: "wide:  %d frames · %.1f fps", w, Double(w) / secs))
            line(String(format: "tele:  %d frames · %.1f fps", t, Double(t) / secs))
            line("thermal after: \(thermalName(ProcessInfo.processInfo.thermalState))")
            line("both streams delivering: \(w > 0 && t > 0 ? "✅ YES — 广角+长焦并发可行" : "❌ NO")")
            line("──────────────────────────────")
            MultiCamProbe.live = nil
        }
    }

    // MARK: - wiring helpers

    /// Multicam needs MANUAL connections (addInput/OutputWithNoConnections +
    /// explicit AVCaptureConnection) so each port maps to exactly one output —
    /// the auto-connect path over-connects and inflates hardwareCost.
    private func wire(device: AVCaptureDevice, output: AVCaptureVideoDataOutput, label: String) -> Bool {
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            line("\(label): input init failed"); return false
        }
        guard session.canAddInput(input) else { line("\(label): canAddInput=false"); return false }
        session.addInputWithNoConnections(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else { line("\(label): canAddOutput=false"); return false }
        session.addOutputWithNoConnections(output)

        guard let port = input.ports(for: .video,
                                     sourceDeviceType: device.deviceType,
                                     sourceDevicePosition: device.position).first else {
            line("\(label): no video port"); return false
        }
        let conn = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(conn) else { line("\(label): canAddConnection=false"); return false }
        session.addConnection(conn)
        return true
    }

    private func setMultiCamFormat(on device: AVCaptureDevice, label: String) {
        // Prefer exactly 1920x1080 multicam format; else the LARGEST format
        // within 1080p (so pose gets enough resolution); else any multicam one.
        let multicam = device.formats.filter { $0.isMultiCamSupported }
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        }
        let pick = multicam.first { dims($0).width == 1920 && dims($0).height == 1080 }
            ?? multicam
                .filter { dims($0).width <= 1920 && dims($0).height <= 1080 }
                .max { Int(dims($0).width) * Int(dims($0).height) < Int(dims($1).width) * Int(dims($1).height) }
            ?? multicam.first
        guard let fmt = pick else { line("\(label): no multicam format!"); return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = fmt
            device.unlockForConfiguration()
            let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            line("\(label) format: \(d.width)x\(d.height)")
        } catch {
            line("\(label): lock failed \(error.localizedDescription)")
        }
    }

    private func camera(_ type: AVCaptureDevice.DeviceType) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [type], mediaType: .video, position: .back)
            .devices.first
    }

    // MARK: - delegate (count frames per stream)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lock.lock()
        if output === videoOutWide { wideFrames += 1 }
        else if output === videoOutTele { teleFrames += 1 }
        lock.unlock()
    }
}

private func line(_ s: String) { print("[MultiCam] \(s)") }

private func thermalName(_ s: ProcessInfo.ThermalState) -> String {
    switch s {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}
