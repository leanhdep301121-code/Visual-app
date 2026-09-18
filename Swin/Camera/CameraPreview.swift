import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.lockPortraitRotation()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // Rebind if the session object itself changed — switching capture mode
        // rebuilds it (e.g. AVCaptureSession → AVCaptureMultiCamSession).
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.lockPortraitRotation()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private var startObserver: NSObjectProtocol?

        /// The preview connection doesn't exist until the session's
        /// configuration is committed — and the session bootstraps on a
        /// background queue AFTER this view is created. Setting the rotation
        /// only from make/updateUIView therefore worked only "sometimes"
        /// (test-report item 3: sideways preview). Apply it now if the
        /// connection already exists, and re-apply every time the session
        /// (re)starts — that also covers camera switches and
        /// background→foreground restarts.
        func lockPortraitRotation() {
            applyRotation()
            guard startObserver == nil, let session = previewLayer.session else { return }
            startObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.didStartRunningNotification,
                object: session, queue: .main
            ) { [weak self] _ in
                self?.applyRotation()
            }
        }

        private func applyRotation() {
            if let conn = previewLayer.connection,
               conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90
            }
        }

        deinit {
            if let o = startObserver { NotificationCenter.default.removeObserver(o) }
        }
    }
}
