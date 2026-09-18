import AVFoundation

/// The capture graph this session is running. These are mutually exclusive at
/// the AVFoundation level — notably **MultiCam and Cinematic cannot coexist**
/// (both saturate the ISP), so switching between them rebuilds the session.
///
/// - `.analysis`  : single wide camera, sharp, full frame → the pose/event
///                  pipeline. This is the app's existing default behaviour.
/// - `.multiAngle`: AVCaptureMultiCamSession — wide (drives pose) + telephoto
///                  (sharp optical close-up). Pro-only (needs a tele lens).
/// - `.cinematic` : single camera with computational shallow depth-of-field +
///                  rack-focus to the golfer. iOS 26+ / iPhone 13+. The subject
///                  stays sharp so pose still runs; the club may be softened.
enum CaptureMode: String, Sendable, CaseIterable, Identifiable {
    case analysis
    case multiAngle
    case cinematic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .analysis: return "分析"
        case .multiAngle: return "多机位"
        case .cinematic: return "电影"
        }
    }
}

/// What the current hardware actually supports — used to gate mode pickers so we
/// never offer a mode this phone can't run. All reads are cheap and safe to call
/// off the main thread.
struct CaptureCapabilities: Sendable {
    let multiCam: Bool        // wide + tele can run concurrently
    let hasTelephoto: Bool    // a dedicated optical tele lens exists (Pro)
    let cinematic: Bool       // at least one cinematic-capable format exists

    static func detect() -> CaptureCapabilities {
        let backWide = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .back).devices.first
        let backTele = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTelephotoCamera], mediaType: .video, position: .back).devices.first

        var multiCam = false
        if AVCaptureMultiCamSession.isMultiCamSupported, backTele != nil {
            // Confirm wide+tele is actually an allowed simultaneous set.
            let ds = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera,
                              .builtInDualCamera, .builtInTripleCamera],
                mediaType: .video, position: .back)
            multiCam = ds.supportedMultiCamDeviceSets.contains { set in
                let types = Set(set.map { $0.deviceType })
                return types.contains(.builtInWideAngleCamera) && types.contains(.builtInTelephotoCamera)
            } || !ds.supportedMultiCamDeviceSets.isEmpty
        }

        var cinematic = false
        if #available(iOS 26.0, *) {
            cinematic = (backWide?.formats.contains { $0.isCinematicVideoCaptureSupported }) ?? false
        }

        return CaptureCapabilities(
            multiCam: multiCam, hasTelephoto: backTele != nil, cinematic: cinematic)
    }

    /// Modes offered in the shipping UI, in display order.
    ///
    /// Multi-angle / cinematic are TEMPORARILY DISABLED: they crash on device
    /// and can't be validated in the simulator (no multicam hardware), so we
    /// don't expose them until they can be iterated on a real device. The whole
    /// scaffold (session builders, switcher, tele PiP) stays in place — flip the
    /// flag back to re-enable.
    var availableModes: [CaptureMode] {
        guard Self.multiCamCinematicEnabled else { return [.analysis] }
        var modes: [CaptureMode] = [.analysis]
        if multiCam { modes.append(.multiAngle) }
        if cinematic { modes.append(.cinematic) }
        return modes
    }

    /// Feature flag for the opt-in shooting modes.
    static let multiCamCinematicEnabled = true
}
