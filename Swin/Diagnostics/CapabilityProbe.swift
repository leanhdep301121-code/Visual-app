import AVFoundation
import CoreVideo
import Foundation
import Speech
import Vision

/// One-shot, read-only capability report for the planned capture-rig features
/// (multi-cam, gesture, voice, auto exposure/focus, thermal). Mirrors
/// `LatencyBench`: runs on a background thread at launch and prints to the
/// Xcode console. Gated behind env `CAPPROBE=1` so it never fires for normal
/// users — see `SwinApp.init`.
///
/// IMPORTANT: this probe is strictly **read-only**. It enumerates devices and
/// reads capability flags but NEVER adds an input, starts the session, or
/// requests camera/mic/speech authorization — so it triggers no permission
/// prompts and is safe to run anywhere. The numbers only mean something on a
/// real device; the simulator has no cameras and reports defaults/false.
enum CapabilityProbe {
    static func runOnce() {
        Task.detached(priority: .background) {
            line("──────── capability probe ────────")
            probeMultiCam()
            probeCameras()
            probeExposureFocus()
            probeCinematic()
            probeGesture()
            await probeVoice()
            probeThermal()
            line("──────────────────────────────────")
        }
    }

    // MARK: - multi-cam (挥杆 + 特写 并发)

    private static func probeMultiCam() {
        let supported = AVCaptureMultiCamSession.isMultiCamSupported
        line("multicam supported: \(yn(supported))  (need A12+/iPhone XS+ for 广角+长焦特写)")
        guard supported else { return }
        // supportedMultiCamDeviceSets tells us WHICH physical cameras can run
        // at the same time — this is what decides "挥杆广角 + 特写长焦 并发".
        let ds = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera,
                          .builtInTelephotoCamera, .builtInDualCamera,
                          .builtInDualWideCamera, .builtInTripleCamera],
            mediaType: .video, position: .unspecified)
        let sets = ds.supportedMultiCamDeviceSets
        if sets.isEmpty {
            line("  multicam device-sets: — (none reported)")
        } else {
            for (i, s) in sets.enumerated() {
                let names = s.map { "\(short($0.deviceType))/\($0.position == .back ? "B" : "F")" }
                line("  set[\(i)]: \(names.sorted().joined(separator: " + "))")
            }
        }
    }

    // MARK: - cinematic video (虚化 / 目标对焦 / rack-focus 特写, iOS 26+)

    private static func probeCinematic() {
        guard #available(iOS 26.0, *) else {
            line("cinematic video: needs iOS 26+ (this OS older) — skipped")
            return
        }
        for (label, type, pos) in [("back dualWide", AVCaptureDevice.DeviceType.builtInDualWideCamera, AVCaptureDevice.Position.back),
                                   ("front trueDepth", .builtInTrueDepthCamera, .front)] {
            guard let dev = AVCaptureDevice.DiscoverySession(
                deviceTypes: [type], mediaType: .video, position: pos).devices.first else {
                line("cinematic \(label): device absent — skipped"); continue
            }
            let cineFormats = dev.formats.filter { $0.isCinematicVideoCaptureSupported }
            if let f = cineFormats.first {
                line(String(format: "cinematic \(label): ✅ %d formats · aperture f/%.1f…f/%.1f (default f/%.1f)",
                            cineFormats.count, f.minSimulatedAperture, f.maxSimulatedAperture, f.defaultSimulatedAperture))
            } else {
                line("cinematic \(label): ❌ no cinematic-capable format")
            }
        }
        line("  note: Cinematic 与 MultiCam 互斥;30fps only;主体清晰背景虚化(对 pose 友好)")
    }

    // MARK: - available cameras per position

    private static func probeCameras() {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
        ]
        for position in [AVCaptureDevice.Position.back, .front] {
            let ds = AVCaptureDevice.DiscoverySession(
                deviceTypes: types, mediaType: .video, position: position)
            let names = ds.devices.map { short($0.deviceType) }
            let tag = position == .back ? "back " : "front"
            line("cameras \(tag): \(names.isEmpty ? "—" : names.joined(separator: ", "))")
        }
    }

    // MARK: - auto exposure / focus knobs (逆光测光 + 对焦人)

    private static func probeExposureFocus() {
        guard let dev = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .back
        ).devices.first else {
            line("exposure/focus: no back camera (simulator?) — skipped")
            return
        }
        line(String(format: "exposure POI: %@  bias range: %.1f…%.1f EV",
                    yn(dev.isExposurePointOfInterestSupported),
                    dev.minExposureTargetBias, dev.maxExposureTargetBias))
        line("focus POI: \(yn(dev.isFocusPointOfInterestSupported))  far-restriction: \(yn(dev.isAutoFocusRangeRestrictionSupported))  smooth-AF: \(yn(dev.isSmoothAutoFocusSupported))")
        line("video HDR: \(yn(dev.activeFormat.isVideoHDRSupported))  face-driven AE auto: \(yn(dev.automaticallyAdjustsFaceDrivenAutoExposureEnabled))  face-driven AF auto: \(yn(dev.automaticallyAdjustsFaceDrivenAutoFocusEnabled))")
    }

    // MARK: - hand-pose gesture (一个手势让云台转过来)

    private static func probeGesture() {
        // Confirm the Vision hand-pose path actually executes on this OS.
        guard let pb = grayBuffer(width: 640, height: 480) else {
            line("gesture: buffer alloc failed — skipped"); return
        }
        let req = VNDetectHumanHandPoseRequest()
        req.maximumHandCount = 2
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        do {
            try handler.perform([req])
            let n = req.results?.count ?? 0
            line("gesture (VNDetectHumanHandPose): ✅ ran, \(n) hands on blank frame (expect 0)")
        } catch {
            line("gesture: ❌ \(error.localizedDescription)")
        }
        line("  note: 大动作(举手过头)可直接用现有全身 pose 判,省一份模型/热预算")
    }

    // MARK: - on-device voice (一句话让云台转过来)

    private static func probeVoice() async {
        for code in ["zh-Hans", "en-US"] {
            guard let rec = SFSpeechRecognizer(locale: Locale(identifier: code)) else {
                line("voice \(code): recognizer unavailable"); continue
            }
            // supportsOnDeviceRecognition does not require authorization.
            line("voice \(code): available=\(yn(rec.isAvailable)) on-device=\(yn(rec.supportsOnDeviceRecognition))")
        }
        line("  note: 被动语音需常驻麦,与 CameraService 故意不占麦 + TTS 占会话冲突 → MVP 先手势/只做主动")
    }

    // MARK: - thermal headroom (风扇前后对比基线)

    private static func probeThermal() {
        line("thermal now: \(thermalName(ProcessInfo.processInfo.thermalState))  (加风扇前后各跑一轮多摄+多模型,量维持 nominal/fair 的时长)")
    }

    // MARK: - helpers

    private static func line(_ s: String) { print("[Capability] \(s)") }
    private static func yn(_ b: Bool) -> String { b ? "✅" : "❌" }

    private static func short(_ t: AVCaptureDevice.DeviceType) -> String {
        switch t {
        case .builtInWideAngleCamera: return "wide"
        case .builtInUltraWideCamera: return "ultrawide"
        case .builtInTelephotoCamera: return "tele"
        case .builtInDualCamera: return "dual"
        case .builtInDualWideCamera: return "dualWide"
        case .builtInTripleCamera: return "triple"
        default: return t.rawValue
        }
    }

    private static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func grayBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
                == kCVReturnSuccess, let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        if let base = CVPixelBufferGetBaseAddress(buf) {
            memset(base, 128, CVPixelBufferGetDataSize(buf))
        }
        return buf
    }
}
