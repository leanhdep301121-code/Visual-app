import Foundation
import Photos

/// Saves a finished video file straight into the system Photos library (相册).
/// Used so capture-lab kept clips land in the camera roll where they're easy to
/// review / AirDrop — no Xcode container digging. Add-only authorization, which
/// matches the bundled `NSPhotoLibraryAddUsageDescription`.
enum PhotoSaver {
    static func saveVideo(_ url: URL, completion: ((Bool) -> Void)? = nil) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                dbg(.warn, tag: "photos", "library access not granted (\(status.rawValue))")
                completion?(false); return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, err in
                if let err { dbg(.error, tag: "photos", "save failed: \(err.localizedDescription)") }
                else { dbg(tag: "photos", "saved \(url.lastPathComponent) → 相册") }
                completion?(ok)
            }
        }
    }
}
