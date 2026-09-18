import Observation
import ReplayKit
import SwiftUI

/// ReplayKit wrapper for filming the AR pro-swing session (the ARvid loop:
/// place the pro in your camera view → move to frame him → REC → get a video
/// to keep/share). Screen recording captures the composited AR view;
/// controls are hidden by the host view while recording so the file is clean.
///
/// Device-only at runtime (`RPScreenRecorder.isAvailable` is false in the
/// simulator) — callers gate the REC button on `isAvailable`.
@Observable
final class HologramRecorder {
    private(set) var isRecording = false
    /// Apple's trim/save/share sheet, handed to us when a recording stops.
    var preview: RPPreviewViewController?

    var isAvailable: Bool { RPScreenRecorder.shared().isAvailable }

    func start() {
        let rec = RPScreenRecorder.shared()
        guard rec.isAvailable, !rec.isRecording else { return }
        rec.isMicrophoneEnabled = false          // framing practice; no mic (no plist key needed)
        rec.startRecording { [weak self] error in
            DispatchQueue.main.async {
                self?.isRecording = (error == nil)
                if let error { dbg(tag: "holo", "REC start failed: \(error.localizedDescription)") }
            }
        }
    }

    func stop() {
        let rec = RPScreenRecorder.shared()
        guard rec.isRecording else { isRecording = false; return }
        rec.stopRecording { [weak self] previewVC, error in
            DispatchQueue.main.async {
                self?.isRecording = false
                if let error { dbg(tag: "holo", "REC stop failed: \(error.localizedDescription)") }
                self?.preview = previewVC        // host presents Apple's save/share sheet
            }
        }
    }

    // MARK: - file capture (self-test path)

    /// Buffer-level capture straight to an mp4 — used by the HOLOREC=1
    /// self-test to verify the recording pipeline end-to-end without a human
    /// tapping Apple's preview sheet. Same RPScreenRecorder source as the
    /// user path, so a passing file proves capture works here.
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var bufferCount = 0

    func startCaptureToFile(_ url: URL) {
        let rec = RPScreenRecorder.shared()
        guard rec.isAvailable, !rec.isRecording else {
            dbg(tag: "holo", "capture unavailable"); return
        }
        try? FileManager.default.removeItem(at: url)
        rec.isMicrophoneEnabled = false
        rec.startCapture(handler: { [weak self] sample, type, error in
            guard let self, error == nil, type == .video, CMSampleBufferIsValid(sample) else { return }
            self.bufferCount += 1
            if self.bufferCount == 1 { dbg(tag: "holo", "first video buffer arrived") }
            self.append(sample, to: url)
        }, completionHandler: { error in
            DispatchQueue.main.async {
                if let error { dbg(tag: "holo", "startCapture failed: \(error.localizedDescription)") }
                else { dbg(tag: "holo", "capture running → \(url.lastPathComponent)") }
            }
        })
    }

    private func append(_ sample: CMSampleBuffer, to url: URL) {
        if writer == nil {
            guard let pb = CMSampleBufferGetImageBuffer(sample),
                  let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: CVPixelBufferGetWidth(pb),
                AVVideoHeightKey: CVPixelBufferGetHeight(pb),
            ])
            input.expectsMediaDataInRealTime = true
            w.add(input)
            w.startWriting()
            writer = w
            writerInput = input
        }
        guard let writer, let writerInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if !sessionStarted { writer.startSession(atSourceTime: pts); sessionStarted = true }
        if writerInput.isReadyForMoreMediaData { writerInput.append(sample) }
    }

    func stopCapture(completion: @escaping (String) -> Void) {
        RPScreenRecorder.shared().stopCapture { [weak self] error in
            guard let self else { return }
            if let error { completion("stopCapture err: \(error.localizedDescription) buffers=\(self.bufferCount)"); return }
            guard let writer = self.writer else { completion("no frames written, buffers=\(self.bufferCount)"); return }
            self.writerInput?.markAsFinished()
            writer.finishWriting {
                let attrs = try? FileManager.default.attributesOfItem(atPath: writer.outputURL.path)
                let size = attrs?[.size] as? Int ?? 0
                self.writer = nil; self.writerInput = nil; self.sessionStarted = false
                completion("finished \(writer.outputURL.lastPathComponent) bytes=\(size)")
            }
        }
    }
}

/// Wraps Apple's `RPPreviewViewController` (trim / save to Photos / share)
/// for SwiftUI presentation. Dismisses itself via the ReplayKit delegate.
struct RecordingPreview: UIViewControllerRepresentable {
    let controller: RPPreviewViewController
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> RPPreviewViewController {
        controller.previewControllerDelegate = context.coordinator
        controller.modalPresentationStyle = .fullScreen
        return controller
    }

    func updateUIViewController(_ uiViewController: RPPreviewViewController, context: Context) {}

    final class Coordinator: NSObject, RPPreviewViewControllerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func previewControllerDidFinish(_ previewController: RPPreviewViewController) {
            onDone()
        }
    }
}
