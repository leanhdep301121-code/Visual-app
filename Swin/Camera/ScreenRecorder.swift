import Foundation
import Observation
import Photos
import ReplayKit

/// Thin wrapper around ReplayKit's `RPScreenRecorder` for in-app screen
/// capture, then saves the resulting mp4 to the user's Photos library.
///
/// Records ALL on-screen pixels (camera preview + HUD + feedback card),
/// which is what we want for "share my session" clips. Microphone is
/// disabled — we already have AVCaptureSession owning the audio stream
/// for swing recording.
@Observable
@MainActor
final class ScreenRecorder {
    private(set) var isRecording: Bool = false
    /// Path of the most recently saved clip (also written to Photos).
    /// Useful for the UI to show a "saved!" toast.
    private(set) var lastSavedURL: URL?

    enum ScreenRecorderError: LocalizedError {
        case notAvailable
        case alreadyRecording
        case notRecording
        case photoLibraryDenied
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAvailable:      return "Screen recording is not available on this device."
            case .alreadyRecording:  return "Already recording."
            case .notRecording:      return "Not currently recording."
            case .photoLibraryDenied: return "Photos library access denied."
            case .saveFailed(let m): return "Save failed: \(m)"
            }
        }
    }

    func start() async throws {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else { throw ScreenRecorderError.notAvailable }
        guard !recorder.isRecording else { throw ScreenRecorderError.alreadyRecording }
        recorder.isMicrophoneEnabled = false
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            recorder.startRecording { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
        isRecording = true
        print("[ScreenRecorder] started")
    }

    /// Stop recording and write the result to Photos. Throws on permission or IO failure.
    func stopAndSaveToPhotos() async throws {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isRecording else { throw ScreenRecorderError.notRecording }

        // Pick a unique mp4 path under the app's tmp dir.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swin_screen_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)

        // iOS 15+: stopRecording(withOutput:) writes the recording to file directly.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            recorder.stopRecording(withOutput: url) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
        isRecording = false
        print("[ScreenRecorder] stopped, wrote \(url.path)")

        // Save to Photos library.
        let status = await requestPhotoAddAuthorization()
        guard status == .authorized || status == .limited else {
            lastSavedURL = url
            throw ScreenRecorderError.photoLibraryDenied
        }
        try await saveVideoToPhotos(at: url)
        lastSavedURL = url
        print("[ScreenRecorder] saved to Photos")
    }

    private func requestPhotoAddAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current != .notDetermined { return current }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                cont.resume(returning: status)
            }
        }
    }

    private func saveVideoToPhotos(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { success, error in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: ScreenRecorderError.saveFailed(error?.localizedDescription ?? "unknown"))
                }
            }
        }
    }
}
