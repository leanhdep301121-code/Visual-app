import AVFoundation
import Foundation

/// Drives the iOS 26 Cinematic Video capture path: shallow depth-of-field
/// (computational bokeh) + rack-focus that tracks the golfer. The subject stays
/// sharp (so pose still runs); only the background is blurred.
///
/// Lifecycle: `CaptureController` picks a cinematic format + enables it on the
/// input, then hands metadata here so we can lock focus onto the detected
/// person. Bokeh strength is the simulated f-number (`simulatedAperture`).
@available(iOS 26.0, *)
final class CinematicController: @unchecked Sendable {
    private let device: AVCaptureDevice
    private let input: AVCaptureDeviceInput
    private let queue: DispatchQueue
    private var trackedID: Int?

    let minAperture: Float
    let maxAperture: Float
    private(set) var aperture: Float

    init?(device: AVCaptureDevice, input: AVCaptureDeviceInput, queue: DispatchQueue) {
        guard let fmt = device.formats.first(where: { $0.isCinematicVideoCaptureSupported }) else { return nil }
        self.device = device
        self.input = input
        self.queue = queue
        self.minAperture = fmt.minSimulatedAperture
        self.maxAperture = fmt.maxSimulatedAperture
        self.aperture = fmt.defaultSimulatedAperture
    }

    /// The cinematic-capable format to install before adding the input. Call on
    /// the session queue inside begin/commitConfiguration.
    static func cinematicFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats.first { $0.isCinematicVideoCaptureSupported }
    }

    /// Metadata types the cinematic pipeline needs the metadata output to emit.
    static func requiredMetadataTypes(_ output: AVCaptureMetadataOutput) -> [AVMetadataObject.ObjectType] {
        output.requiredMetadataObjectTypesForCinematicVideoCapture
    }

    /// Bokeh strength. Smaller f-number = larger aperture = stronger blur.
    func setAperture(_ f: Float) {
        let clamped = min(maxAperture, max(minAperture, f))
        queue.async { [self] in
            input.simulatedAperture = clamped
            aperture = clamped
        }
    }

    /// On each metadata batch, keep cinematic focus locked on the most prominent
    /// person/face (the golfer). Uses a strong lock so it doesn't rack away to a
    /// bystander walking through the range.
    func onMetadata(_ objects: [AVMetadataObject]) {
        // Prefer person/face objects; pick the largest by bounds area.
        let subjects = objects.filter {
            $0.type == .humanFullBody || $0.type == .face
        }
        guard let best = subjects.max(by: { $0.bounds.area < $1.bounds.area }) else { return }
        let id = best.objectID
        if id == trackedID { return }
        trackedID = id
        queue.async { [self] in
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.setCinematicVideoTrackingFocus(detectedObjectID: id, focusMode: .strong)
            device.unlockForConfiguration()
        }
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
