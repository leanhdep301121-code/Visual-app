import RealityKit
import UIKit

/// The hologram scene node shared by the device AR view and the simulator
/// stage: a vertical plane cycling pre-loaded frame textures (the pro swing)
/// standing on a cyan "projection pad" glow. Base of `root` sits at y = 0.
///
/// Frame stepping happens in `advance(_:)`, driven by the host's RealityKit
/// scene-update event — GPU texture swaps only, nothing decodes and SwiftUI
/// never redraws, so playback cannot flicker. `speed` scales the native fps
/// (0.25× / 0.5× slow-mo study); `paused` freezes the pose.
final class HologramPuppet {
    let root = Entity()
    let clip: HologramClip

    var speed: Double = 1.0
    var paused = false

    /// Only the flat figure billboards; pad, ball and film-spot marker stay
    /// fixed on the floor (world landmarks — they make orbiting visible and
    /// give the "where to film from" cue).
    private let spinner = Entity()
    private let figure: ModelEntity
    private var materials: [UnlitMaterial]
    private var acc: Double = 0
    private var idx = 0

    // Shot effect: ball launches at the clip's impact frame and draws a
    // broadcast-style shot tracer — a smooth camera-facing RIBBON (hot white
    // core inside a soft cyan bloom, fading toward the tail) rebuilt from the
    // flight path every frame. The full curve hangs in the air through the
    // next backswing and clears at the next impact.
    private var ball: ModelEntity?
    private var ballGlow: ModelEntity?
    private let ballHome: SIMD3<Float> = [0.42, 0.022, 0.12]
    private var tracerCore: ModelEntity?
    private var tracerBloom: ModelEntity?
    private var coreMaterial: UnlitMaterial?
    private var bloomMaterial: UnlitMaterial?
    private var path: [SIMD3<Float>] = []
    private var impactFlash: ModelEntity?
    private var landingRing: ModelEntity?
    private var landingRing2: ModelEntity?
    private var shotT: Double? = nil          // seconds since impact; nil = armed
    private var flashT: Double? = nil
    private var landingT: Double? = nil
    private var lastCam: SIMD3<Float> = [0, 1.5, 4]
    // ambient life: breathing pad, inviting film-ring, pop-in, landing bounce
    private var padEntity: ModelEntity?
    private var filmRing: ModelEntity?
    private var clock: Double = 0
    private var popT: Double? = nil           // seconds since placement pop started
    private var bounceT: Double? = nil        // seconds since touchdown bounce started
    private var landPos: SIMD3<Float> = .zero
    // Real driver ballistics (Toptracer-faithful): ~55 m/s at ~13° launch.
    // The tracer recedes toward the horizon and perspective does the taper —
    // that's what reads "broadcast" instead of "game power-up lob".
    private let shotVh: Float = 53.6          // horizontal m/s
    private let shotVy: Float = 12.4          // vertical m/s → apex ≈ 7.8 m

    init?(clip: HologramClip) {
        guard let mats = Self.materialCache(for: clip), !mats.isEmpty else { return nil }
        self.clip = clip
        self.materials = mats

        let h = clip.realHeightMeters
        let w = h * clip.aspect
        figure = ModelEntity(mesh: .generatePlane(width: w, height: h), materials: [mats[0]])
        figure.position.y = h / 2                    // feet on the floor
        spinner.addChild(figure)
        root.addChild(spinner)

        if let padMat = Self.glowMaterial() {
            let pad = ModelEntity(mesh: .generatePlane(width: w * 1.5, depth: w * 0.8),
                                  materials: [padMat])
            pad.position.y = 0.01                    // just above floor, no z-fight
            root.addChild(pad)
            padEntity = pad
        }

        // Contact shadow under the feet — grounds the figure on the pad.
        if let shadowMat = Self.shadowMaterial() {
            let shadow = ModelEntity(mesh: .generatePlane(width: 0.62, depth: 0.30),
                                     materials: [shadowMat])
            shadow.position = [0, 0.015, 0]
            root.addChild(shadow)
        }

        // Golf ball on the turf — the tee'd ball that LAUNCHES at impact.
        let b = ModelEntity(mesh: .generateSphere(radius: 0.022),
                            materials: [UnlitMaterial(color: .white)])
        b.position = ballHome
        root.addChild(b)
        ball = b
        if let shadowMat = Self.shadowMaterial() {
            let ballShadow = ModelEntity(mesh: .generatePlane(width: 0.09, depth: 0.05),
                                         materials: [shadowMat])
            ballShadow.position = [ballHome.x, 0.012, ballHome.z]
            root.addChild(ballShadow)
        }
        buildShotEffect()

        // "Film from here" ring — the down-the-line camera spot. Stand on it
        // (device) / orbit onto it (simulator) to see the filming angle.
        if let ringMat = Self.ringMaterial() {
            let ring = ModelEntity(mesh: .generatePlane(width: 0.55, depth: 0.55),
                                   materials: [ringMat])
            ring.position = [1.05, 0.012, 0.68]
            root.addChild(ring)
            filmRing = ring
        }
    }

    /// Step the swing loop + shot effect. Call from a scene-update handler.
    func advance(_ deltaTime: Double) {
        guard !paused, materials.count > 1 else { return }
        let dtEff = deltaTime * speed
        acc += deltaTime * clip.fps * speed
        let steps = Int(acc)
        if steps > 0 {
            acc -= Double(steps)
            let prev = idx
            idx = (idx + steps) % materials.count
            figure.model?.materials = [materials[idx]]
            if idx < prev {                                      // loop wrapped:
                shotT = nil                                      // end the flight,
                ball?.isEnabled = true                           // ball back on tee,
                ball?.position = ballHome                        // curve keeps hanging
                ballGlow?.isEnabled = false
            }
            let crossed = (prev < clip.impactFrame && idx >= clip.impactFrame)
            if crossed && shotT == nil { triggerShot() }
        }
        tickShot(dtEff)
        tickAmbient(deltaTime)
    }

    /// Trigger the placement pop-in (called right after the hologram lands
    /// on the floor / appears on the stage).
    func popIn() {
        popT = 0
        root.scale = SIMD3<Float>(repeating: 0.82)
    }

    /// Ambient life, real-time paced (independent of slow-mo): breathing pad,
    /// gently pulsing film-ring, springy pop-in, landing bounce.
    private func tickAmbient(_ dt: Double) {
        clock += dt
        if let pad = padEntity {
            let b = 1 + 0.045 * Float(sin(clock * 1.5))
            pad.scale = SIMD3<Float>(b, 1, b)
        }
        if let ring = filmRing {
            let b = 1 + 0.06 * Float(sin(clock * 2.1 + 1.0))
            ring.scale = SIMD3<Float>(b, 1, b)
            ring.orientation = simd_quatf(angle: Float(clock * 0.35), axis: [0, 1, 0])
        }
        if var t = popT {
            t += dt; popT = t
            let p = Float(min(1, t / 0.42))
            // ease-out-back: overshoot to ~1.03 then settle
            let e = 1 + 2.2 * pow(p - 1, 3) + 1.2 * pow(p - 1, 2)
            root.scale = SIMD3<Float>(repeating: 0.82 + (1 - 0.82) * e)
            if p >= 1 { root.scale = .one; popT = nil }
        }
        if var t = bounceT, let ball {
            t += dt; bounceT = t
            // two decaying hops after touchdown, then rest & fade out
            let h: Float
            if t < 0.30 { h = 0.11 * Float(sin(.pi * t / 0.30)) }
            else if t < 0.48 { h = 0.035 * Float(sin(.pi * (t - 0.30) / 0.18)) }
            else { h = 0 }
            ball.position = [landPos.x, 0.022 + h, landPos.z]
            if t > 0.75 { ball.isEnabled = false; bounceT = nil }
        }
    }

    // MARK: - shot effect

    private func buildShotEffect() {
        // Tracer ribbons: meshes are rebuilt from `path` each frame.
        let coreMat = Self.ribbonMaterial(color: .white, maxAlpha: 0.95)
        coreMaterial = coreMat
        let core = ModelEntity(mesh: .generatePlane(width: 0.001, height: 0.001),
                               materials: [coreMat])
        core.isEnabled = false
        root.addChild(core)
        tracerCore = core

        let amber = UIColor(red: 1.0, green: 0.40, blue: 0.16, alpha: 1)   // Toptracer red-orange
        let bloomMat = Self.ribbonMaterial(color: amber, maxAlpha: 0.30)
        bloomMaterial = bloomMat
        let bloom = ModelEntity(mesh: .generatePlane(width: 0.001, height: 0.001),
                                materials: [bloomMat])
        bloom.isEnabled = false
        root.addChild(bloom)
        tracerBloom = bloom

        // Soft glow sprite riding on the ball head.
        if let glowMat = Self.radialMaterial(stops: [(UIColor.white.withAlphaComponent(0.9), 0),
                                                     (amber.withAlphaComponent(0.30), 0.45),
                                                     (amber.withAlphaComponent(0), 1)]) {
            let g = ModelEntity(mesh: .generatePlane(width: 0.14, height: 0.14),
                                materials: [glowMat])
            g.isEnabled = false
            root.addChild(g)
            ballGlow = g
        }
        if let flashMat = Self.radialMaterial(stops: [(UIColor.white.withAlphaComponent(0.85), 0),
                                                      (UIColor(red: 1.0, green: 0.78, blue: 0.40, alpha: 0.35), 0.5),
                                                      (UIColor(red: 1.0, green: 0.72, blue: 0.30, alpha: 0), 1)]) {
            let flash = ModelEntity(mesh: .generatePlane(width: 1, depth: 1), materials: [flashMat])
            flash.position = [ballHome.x, 0.02, ballHome.z]
            flash.isEnabled = false
            root.addChild(flash)
            impactFlash = flash
        }
        if let ringMat = Self.ringMaterial(color: UIColor(red: 1.0, green: 0.72, blue: 0.30, alpha: 1)) {
            let ring = ModelEntity(mesh: .generatePlane(width: 1, depth: 1), materials: [ringMat])
            ring.isEnabled = false
            root.addChild(ring)
            landingRing = ring
            let ring2 = ModelEntity(mesh: .generatePlane(width: 1, depth: 1), materials: [ringMat])
            ring2.isEnabled = false
            root.addChild(ring2)
            landingRing2 = ring2
        }
    }

    private func triggerShot() {
        path.removeAll(keepingCapacity: true)      // clear last shot's curve
        landingRing?.isEnabled = false
        shotT = 0
        flashT = 0
        landingT = nil
        impactFlash?.isEnabled = true
        tracerCore?.isEnabled = true
        tracerBloom?.isEnabled = true
    }

    private func tickShot(_ dt: Double) {
        // impact flash: quick expanding fade at the tee
        if var ft = flashT, let flash = impactFlash {
            ft += dt; flashT = ft
            let p = Float(min(1, ft / 0.22))
            flash.scale = SIMD3<Float>(repeating: 0.12 + 0.33 * p)
            if p >= 1 { flash.isEnabled = false; flashT = nil }
        }
        // landing: double ripple — second ring trails the first by 0.14 s
        if var lt = landingT, let ring = landingRing {
            lt += dt; landingT = lt
            let p = Float(min(1, lt / 0.5))
            ring.scale = SIMD3<Float>(repeating: 0.2 + 0.8 * p)
            if let r2 = landingRing2 {
                let p2 = Float(min(1, max(0, (lt - 0.14) / 0.5)))
                r2.position = ring.position
                r2.isEnabled = lt > 0.14 && p2 < 1
                r2.scale = SIMD3<Float>(repeating: 0.15 + 0.65 * p2)
            }
            if p >= 1, (landingRing2?.isEnabled != true) {
                ring.isEnabled = false; landingT = nil
            } else if p >= 1 {
                ring.isEnabled = false
            }
        }
        // ball flight (ballistic), path sampling, ribbon rebuild
        if var t = shotT, let ball {
            t += dt; shotT = t
            let ft = Float(t)
            var dir = clip.launchDirection; dir.y = 0
            let n = simd_length(dir) > 1e-5 ? simd_normalize(dir) : SIMD3<Float>(0, 0, -1)
            let pos = ballHome + n * (shotVh * ft)
                + SIMD3<Float>(0, shotVy * ft - 4.9 * ft * ft, 0)
            if pos.y <= 0.02 && ft > 0.2 {                 // touched down far away
                ballGlow?.isEnabled = false
                ball.isEnabled = false                     // too distant to resolve
                shotT = nil                                // flight over; curve hangs
            } else if ft > 2.4 {
                ballGlow?.isEnabled = false
                ball.isEnabled = false
                shotT = nil
            } else {
                ball.position = pos
                if let g = ballGlow {
                    g.isEnabled = true
                    g.position = pos
                    g.look(at: lastCam, from: pos, relativeTo: nil)
                }
                if path.last.map({ simd_distance($0, pos) > 0.9 }) ?? true {
                    path.append(pos)                       // ~1 m sampling; spline smooths
                    if path.count > 160 { path.removeFirst() }
                }
            }
        }
        rebuildRibbons()                                   // camera-facing every frame
    }

    /// Rebuild the two tracer ribbons (core + bloom) as camera-facing strips
    /// along `path`, with UV.x = position along the curve (drives the fade).
    private func rebuildRibbons() {
        guard let tracerCore, let tracerBloom else { return }
        guard path.count >= 2 else {
            tracerCore.isEnabled = false
            tracerBloom.isEnabled = false
            return
        }
        if let m = Self.ribbonMesh(path: path, width: 0.013, camera: lastCam, towardCamera: 0.008), let mat = coreMaterial {
            tracerCore.model = ModelComponent(mesh: m, materials: [mat])
            tracerCore.isEnabled = true
        }
        if let m = Self.ribbonMesh(path: path, width: 0.042, camera: lastCam), let mat = bloomMaterial {
            tracerBloom.model = ModelComponent(mesh: m, materials: [mat])
            tracerBloom.isEnabled = true
        }
    }

    private static func ribbonMesh(path: [SIMD3<Float>], width: Float,
                                   camera: SIMD3<Float>, towardCamera: Float = 0) -> MeshResource? {
        let n = path.count
        var pos: [SIMD3<Float>] = []; pos.reserveCapacity(n * 2)
        var uv: [SIMD2<Float>] = []; uv.reserveCapacity(n * 2)
        for (i, pRaw) in path.enumerated() {
            let tangent: SIMD3<Float> = i < n - 1 ? path[i + 1] - pRaw : pRaw - path[i - 1]
            let toCamV = camera - pRaw
            let toCamN = simd_normalize(toCamV)
            let p = pRaw + toCamN * towardCamera      // lift off coplanar sibling (kills banding)
            var side = simd_cross(simd_normalize(tangent), toCamN)
            let len = simd_length(side)
            side = len > 1e-4 ? side / len : SIMD3<Float>(0, 1, 0)
            let t = Float(i) / Float(n - 1)
            let w = width * (0.55 + 0.45 * t) / 2          // taper: thin tail → full head
            pos.append(p + side * w); pos.append(p - side * w)
            uv.append([t, 0]); uv.append([t, 1])
        }
        var idx: [UInt32] = []; idx.reserveCapacity((n - 1) * 12)
        for i in 0..<(n - 1) {
            let a = UInt32(2 * i), b = a + 1, c = a + 2, d = a + 3
            idx += [a, b, c, b, d, c]          // front winding
            idx += [a, c, b, b, c, d]          // back winding — double-sided,
        }                                       // no iOS18-only faceCulling API
        var desc = MeshDescriptor(name: "tracer")
        desc.positions = MeshBuffers.Positions(pos)
        desc.textureCoordinates = MeshBuffers.TextureCoordinates(uv)
        desc.primitives = .triangles(idx)
        return try? MeshResource.generate(from: [desc])
    }

    /// Unlit transparent material whose alpha ramps up along UV.x — the
    /// tracer fades in from the tail to a hot head.
    private static func ribbonMaterial(color: UIColor, maxAlpha: CGFloat) -> UnlitMaterial {
        let w = 256, h = 8
        let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { ctx in
            let colors = [color.withAlphaComponent(0.04),
                          color.withAlphaComponent(maxAlpha * 0.7),
                          color.withAlphaComponent(maxAlpha)].map { $0.cgColor } as CFArray
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 0.55, 1]) else { return }
            ctx.cgContext.drawLinearGradient(grad, start: .zero,
                                             end: CGPoint(x: w, y: 0), options: [])
        }
        var m = UnlitMaterial()
        if let cg = img.cgImage,
           let tex = try? TextureResource.generate(from: cg, options: .init(semantic: .color)) {
            m.color = .init(tint: .white, texture: .init(tex))
        }
        m.blending = .transparent(opacity: .init(floatLiteral: 1))
        return m
    }

    /// Yaw the flat figure so it faces the camera (ground-plane yaw only —
    /// upright, and the floor landmarks around it do NOT rotate). Also caches
    /// the camera position for the camera-facing tracer ribbons.
    func billboard(towardCameraAt cam: SIMD3<Float>) {
        lastCam = cam
        let pos = spinner.position(relativeTo: nil)
        let dx = cam.x - pos.x, dz = cam.z - pos.z
        guard dx * dx + dz * dz > 1e-5 else { return }
        spinner.setOrientation(simd_quatf(angle: atan2(dx, dz), axis: [0, 1, 0]), relativeTo: nil)
    }

    // MARK: - materials

    /// One UnlitMaterial per frame, built once per clip and cached. Only the
    /// current clip's materials are kept (a clip is ~10-15 MB of texture).
    private static var cache: (id: String, mats: [UnlitMaterial])?

    private static func materialCache(for clip: HologramClip) -> [UnlitMaterial]? {
        if let cache, cache.id == clip.id { return cache.mats }
        var mats: [UnlitMaterial] = []
        mats.reserveCapacity(clip.frameCount)
        for i in 0..<clip.frameCount {
            guard let cg = UIImage(named: clip.frameName(i))?.cgImage,
                  let tex = try? TextureResource.generate(from: cg, options: .init(semantic: .color))
            else { continue }
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(tex))
            m.opacityThreshold = 0.3      // keep the thin club shaft; RVM fgr is decontaminated
            mats.append(m)
        }
        cache = (clip.id, mats)
        return mats
    }

    /// Soft cyan radial glow — the floor "projection pad" under the figure.
    static func glowMaterial() -> UnlitMaterial? {
        let cyan = UIColor(red: 0.36, green: 0.86, blue: 1.0, alpha: 1)
        return radialMaterial(stops: [(cyan.withAlphaComponent(0.22), 0),
                                      (cyan.withAlphaComponent(0.05), 0.55),
                                      (cyan.withAlphaComponent(0), 1)])
    }

    /// Soft dark ellipse — contact shadow (feet / ball).
    static func shadowMaterial() -> UnlitMaterial? {
        radialMaterial(stops: [(UIColor.black.withAlphaComponent(0.55), 0),
                               (UIColor.black.withAlphaComponent(0.25), 0.6),
                               (UIColor.black.withAlphaComponent(0), 1)])
    }

    /// Hollow glow ring (floor markers). Default cyan = the film-spot cue;
    /// amber = the ball's landing ping.
    static func ringMaterial(color: UIColor = UIColor(red: 0.36, green: 0.86, blue: 1.0, alpha: 1)) -> UnlitMaterial? {
        radialMaterial(stops: [(color.withAlphaComponent(0), 0),
                               (color.withAlphaComponent(0), 0.62),
                               (color.withAlphaComponent(0.85), 0.74),
                               (color.withAlphaComponent(0), 0.86),
                               (color.withAlphaComponent(0), 1)])
    }

    /// Radial-gradient unlit material (transparent blending). Used for the
    /// pad glow and the simulator stage ground.
    static func radialMaterial(stops: [(UIColor, CGFloat)], size: Int = 512) -> UnlitMaterial? {
        let img = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let colors = stops.map { $0.0.cgColor } as CFArray
            let locs = stops.map { $0.1 }
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: locs) else { return }
            let c = CGPoint(x: size / 2, y: size / 2)
            ctx.cgContext.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                                             endCenter: c, endRadius: CGFloat(size) / 2, options: [])
        }
        guard let cg = img.cgImage,
              let tex = try? TextureResource.generate(from: cg, options: .init(semantic: .color))
        else { return nil }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(tex))
        m.blending = .transparent(opacity: .init(floatLiteral: 1))
        return m
    }
}
