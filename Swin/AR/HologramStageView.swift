#if targetEnvironment(simulator)
import AVFoundation
import Combine
import RealityKit
import SwiftUI
import UIKit

/// Simulator stand-in that mirrors the DEVICE experience: real range footage
/// (`holo_bg.mp4`, an empty tee looped seamlessly) plays as the "camera
/// feed", and the SAME `HologramPuppet` renders in a TRANSPARENT RealityKit
/// view composited on top — the pro stands on real grass. Tap the grass to
/// move him (the device's tap-to-place, same muscle memory). ARKit itself
/// cannot run in the simulator; this is the closest truthful preview.
struct HologramStageView: View {
    let clip: HologramClip
    let speed: Double
    let paused: Bool

    var body: some View {
        ZStack {
            LoopingVideoView(resource: "holo_bg")
            // cinematic grade: gentle warmth + vignette over the "camera feed"
            LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.6).opacity(0.06),
                                    .clear, .clear,
                                    Color.black.opacity(0.18)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            RadialGradient(colors: [.clear, .clear, .black.opacity(0.22)],
                           center: .center, startRadius: 180, endRadius: 620)
                .allowsHitTesting(false)
            TransparentHoloView(clip: clip, speed: speed, paused: paused)
        }
    }
}

/// Looping, muted, aspect-fill background video (plain H.264 — decodes fine
/// in the simulator, unlike HEVC-alpha).
private struct LoopingVideoView: UIViewRepresentable {
    let resource: String

    final class PlayerContainer: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
    }

    func makeUIView(context: Context) -> PlayerContainer {
        let v = PlayerContainer()
        guard let url = Bundle.main.url(forResource: resource, withExtension: "mp4") else { return v }
        let player = AVQueuePlayer()
        player.isMuted = true
        v.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        v.player = player
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspectFill
        player.play()
        return v
    }

    func updateUIView(_ uiView: PlayerContainer, context: Context) {}
}

/// Transparent RealityKit layer holding the hologram over the footage.
private struct TransparentHoloView: UIViewRepresentable {
    let clip: HologramClip
    let speed: Double
    let paused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(clip: clip) }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        arView.environment.background = .color(.clear)
        arView.backgroundColor = .clear
        arView.isOpaque = false
        context.coordinator.attach(to: arView)
        arView.addGestureRecognizer(UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleTap(_:))))
        arView.addGestureRecognizer(UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handlePan(_:))))
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.updateClip(clip)
        context.coordinator.puppet?.speed = speed
        context.coordinator.puppet?.paused = paused
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject {
        private var clip: HologramClip
        private weak var arView: ARView?
        private(set) var puppet: HologramPuppet?
        private var worldAnchor: AnchorEntity?
        private var updateSub: (any Cancellable)?

        init(clip: HologramClip) { self.clip = clip }

        func attach(to arView: ARView) {
            self.arView = arView
            let anchor = AnchorEntity(world: .zero)

            if let holo = HologramPuppet(clip: clip) {
                holo.root.position = [0, 0, 0.8]      // feet in the foreground grass
                anchor.addChild(holo.root)
                puppet = holo
                holo.popIn()
            }

            // Fixed viewpoint matching the footage: tripod at chest height a
            // few meters behind the tee, looking gently down.
            let cam = PerspectiveCamera()
            cam.look(at: [0, 0.95, 0], from: [0, 1.35, 4.0], relativeTo: nil)
            anchor.addChild(cam)

            arView.scene.addAnchor(anchor)
            worldAnchor = anchor

            updateSub = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                guard let self, let puppet = self.puppet else { return }
                puppet.advance(event.deltaTime)
                puppet.billboard(towardCameraAt: [0, 1.35, 4.0])
            }
        }

        func teardown() {
            updateSub = nil
            puppet = nil
            worldAnchor = nil
        }

        func updateClip(_ newClip: HologramClip) {
            guard newClip.id != clip.id else { return }
            clip = newClip
            guard let worldAnchor, let fresh = HologramPuppet(clip: newClip) else { return }
            if let old = puppet {
                fresh.speed = old.speed
                fresh.paused = old.paused
                fresh.root.position = old.root.position
                old.root.removeFromParent()
            }
            worldAnchor.addChild(fresh.root)
            puppet = fresh
            fresh.popIn()
        }

        // Tap the grass → move the pro there (device tap-to-place analogue).
        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let arView else { return }
            place(at: g.location(in: arView), in: arView)
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let arView else { return }
            if g.state == .changed { place(at: g.location(in: arView), in: arView) }
        }

        /// Cast a ray through the screen point onto the floor plane (y = 0)
        /// and stand the hologram there, clamped to the visible grass.
        private func place(at point: CGPoint, in arView: ARView) {
            guard let puppet,
                  let ray = arView.ray(through: point), ray.direction.y < -1e-4 else { return }
            let t = -ray.origin.y / ray.direction.y
            guard t > 0 else { return }
            let hit = ray.origin + ray.direction * t
            puppet.root.position = [max(-1.4, min(1.4, hit.x)), 0, max(-1.2, min(2.2, hit.z))]
            puppet.popIn()
        }
    }
}
#endif
