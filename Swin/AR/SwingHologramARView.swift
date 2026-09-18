#if !targetEnvironment(simulator)
import ARKit
import Combine
import RealityKit
import SwiftUI
import UIKit

/// Places the life-size pro-swing hologram on a detected floor (device only).
///
///  - `ARCoachingOverlayView` — Apple's standard "move your phone" onboarding
///    until a horizontal plane is found.
///  - person occlusion (`personSegmentationWithDepth`) — real people walking
///    between the phone and the hologram occlude it correctly.
///  - tap → raycast → place / move the hologram on the floor.
///  - billboard — the flat cut-out yaws to face the camera while you walk
///    around it.
///  - frame stepping via `HologramPuppet` (GPU texture swaps; no decode).
struct SwingHologramARView: UIViewRepresentable {
    let clip: HologramClip
    let speed: Double
    let paused: Bool
    /// Fired once the first placement lands, so the UI can drop the hint.
    var onPlaced: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(clip: clip, onPlaced: onPlaced) }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal]
        cfg.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            cfg.frameSemantics.insert(.personSegmentationWithDepth)
        }
        arView.session.run(cfg)

        let coaching = ARCoachingOverlayView()
        coaching.session = arView.session
        coaching.goal = .horizontalPlane
        coaching.activatesAutomatically = true
        coaching.translatesAutoresizingMaskIntoConstraints = false
        arView.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
            coaching.topAnchor.constraint(equalTo: arView.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: arView.bottomAnchor),
        ])

        context.coordinator.attach(to: arView)
        arView.addGestureRecognizer(UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleTap(_:))))
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.updateClip(clip)
        context.coordinator.puppet?.speed = speed
        context.coordinator.puppet?.paused = paused
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.teardown()
        uiView.session.pause()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        private var clip: HologramClip
        private let onPlaced: (() -> Void)?
        private weak var arView: ARView?

        private(set) var puppet: HologramPuppet?
        private var anchor: AnchorEntity?
        private var updateSub: (any Cancellable)?
        private var didFirePlaced = false

        init(clip: HologramClip, onPlaced: (() -> Void)?) {
            self.clip = clip
            self.onPlaced = onPlaced
        }

        func attach(to arView: ARView) {
            self.arView = arView
            updateSub = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                guard let self, let puppet = self.puppet else { return }
                puppet.advance(event.deltaTime)
                if let cam = self.arView?.cameraTransform.translation {
                    puppet.billboard(towardCameraAt: cam)
                }
            }
        }

        func teardown() {
            updateSub = nil
            puppet = nil
            anchor = nil
        }

        /// Swap pro / view on an already-placed hologram, in place.
        func updateClip(_ newClip: HologramClip) {
            guard newClip.id != clip.id else { return }
            clip = newClip
            guard let anchor, let fresh = HologramPuppet(clip: newClip) else { return }
            fresh.speed = puppet?.speed ?? 1
            fresh.paused = puppet?.paused ?? false
            anchor.children.removeAll()
            anchor.addChild(fresh.root)
            puppet = fresh
            fresh.popIn()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView else { return }
            let point = gesture.location(in: arView)
            let results = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal)
            guard let hit = (results.first { $0.anchor is ARPlaneAnchor } ?? results.first) else { return }

            // Move the existing hologram rather than spawning duplicates.
            if let anchor { arView.scene.removeAnchor(anchor) }
            let fresh: HologramPuppet
            if let existing = puppet {
                fresh = existing
                fresh.root.removeFromParent()
            } else if let made = HologramPuppet(clip: clip) {
                fresh = made
            } else { return }

            let newAnchor = AnchorEntity(world: hit.worldTransform)
            newAnchor.addChild(fresh.root)
            arView.scene.addAnchor(newAnchor)
            anchor = newAnchor
            puppet = fresh
            fresh.popIn()

            if !didFirePlaced { didFirePlaced = true; onPlaced?() }
        }
    }
}
#endif
