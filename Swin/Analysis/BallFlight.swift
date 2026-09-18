import CoreGraphics
import Foundation
import simd

/// Metric ball-flight estimate recovered from 2D detections + camera
/// intrinsics. Monocular ballistic fitting is well-posed because gravity's
/// known 9.8 m/s² fixes the absolute scale through the arc's curvature-vs-
/// time coupling (calibrated pinhole camera assumed).
struct BallFlight: Codable, Sendable {
    /// How much the numbers can be trusted. Monocular + estimated intrinsics
    /// puts a hard floor on scale accuracy, so carry is reported as a BAND, not
    /// a figure: `high` ±20 %, `mid` ±35 %, `low` ±60 %. Direction and arc shape
    /// are reliable at every level — it's the absolute scale that slides.
    enum Confidence: String, Codable, Sendable {
        case high, mid, low
        /// Fraction either side of `carryMeters` that the band spans.
        var band: Float { self == .high ? 0.20 : (self == .mid ? 0.35 : 0.6) }
    }

    let speedMps: Float          // launch speed |V|
    let launchAngleDeg: Float    // vs the horizontal plane (up from gravity)
    let carryMeters: Float       // ballistic carry back to launch height
    let reprojErrPx: Float       // mean reprojection error of the fit
    /// Defaulted so reports archived before the band existed still decode.
    var confidence: Confidence = .low

    var carryLoMeters: Float { carryMeters * (1 - confidence.band) }
    var carryHiMeters: Float { carryMeters * (1 + confidence.band) }

    /// Golf talks in yards. The model stays SI (the physics is), so the
    /// conversion lives here rather than at each display site.
    static let yardsPerMeter: Float = 1.09361
    var carryYards: Float { carryMeters * Self.yardsPerMeter }
    var carryLoYards: Float { carryLoMeters * Self.yardsPerMeter }
    var carryHiYards: Float { carryHiMeters * Self.yardsPerMeter }
}

/// Fits P(t) = P0 + V·t + ½·g·t² (camera frame: x right, y down, z forward)
/// to observed pixel points via Gauss-Newton on the pinhole projection.
/// 6 unknowns (P0, V); needs ≥ 5 well-spread points.
enum BallFlightSolver {

    struct Camera {
        let fx: Float, fy: Float, cx: Float, cy: Float
        /// Gravity direction in camera coords (unit); portrait upright ≈ (0,1,0).
        var gravityDir: SIMD3<Float> = [0, 1, 0]
    }

    struct Observation { let u: Float; let v: Float; let t: Float }

    static func solve(_ obs: [Observation], camera: Camera) -> BallFlight? {
        guard let st = fitRaw(obs, camera: camera) else { return nil }
        let V = st.v
        let speed = simd_length(V)
        let up = -simd_normalize(camera.gravityDir)
        let vUp = simd_dot(V, up)
        let launch = asin(max(-1, min(1, vUp / speed))) * 180 / .pi
        let tLast = obs.map(\.t).max() ?? 0
        guard speed.isFinite, speed > 10, speed < 95 else { return nil }
        guard launch > 2, launch < 50 else { return nil }
        guard vUp - 9.8 * tLast > 0 else { return nil }
        let vH = simd_length(V - vUp * up)
        let tLand = max(0, 2 * vUp / 9.8)
        return BallFlight(speedMps: speed, launchAngleDeg: launch,
                          carryMeters: vH * tLand, reprojErrPx: st.err)
    }

    private static func fitRaw(_ obs: [Observation], camera: Camera)
        -> (p0: SIMD3<Float>, v: SIMD3<Float>, err: Float)? {
        guard obs.count >= 5 else { return nil }
        let g = simd_normalize(camera.gravityDir) * 9.8

        // Init: place first point 3 m out along its ray; velocity from the
        // first/last rays at that depth.
        func ray(_ u: Float, _ v: Float) -> SIMD3<Float> {
            simd_normalize(SIMD3<Float>((u - camera.cx) / camera.fx,
                                        (v - camera.cy) / camera.fy, 1))
        }
        let z0: Float = 3
        let p0 = ray(obs[0].u, obs[0].v) * z0 / max(ray(obs[0].u, obs[0].v).z, 0.1)
        let pn = ray(obs[obs.count - 1].u, obs[obs.count - 1].v) * z0
        let dt = max(obs[obs.count - 1].t - obs[0].t, 0.05)
        var x: [Float] = [p0.x, p0.y, p0.z,
                          (pn.x - p0.x) / dt, (pn.y - p0.y) / dt, (pn.z - p0.z) / dt]

        func residuals(_ x: [Float]) -> [Float] {
            var r: [Float] = []
            r.reserveCapacity(obs.count * 2)
            let P0 = SIMD3<Float>(x[0], x[1], x[2])
            let V  = SIMD3<Float>(x[3], x[4], x[5])
            for o in obs {
                let P = P0 + V * o.t + 0.5 * g * o.t * o.t
                let z = max(P.z, 0.05)
                r.append(camera.fx * P.x / z + camera.cx - o.u)
                r.append(camera.fy * P.y / z + camera.cy - o.v)
            }
            return r
        }

        // Gauss-Newton with numeric Jacobian + simple damping.
        var lambda: Float = 1e-2
        var err = rms(residuals(x))
        for _ in 0..<60 {
            let r = residuals(x)
            let m = r.count, n = 6
            var J = [Float](repeating: 0, count: m * n)
            for j in 0..<n {
                var xp = x; let h: Float = max(abs(x[j]) * 1e-3, 1e-3); xp[j] += h
                let rp = residuals(xp)
                for i in 0..<m { J[i * n + j] = (rp[i] - r[i]) / h }
            }
            // Normal equations JᵀJ Δ = -Jᵀr with Levenberg damping.
            var A = [Float](repeating: 0, count: n * n)
            var b = [Float](repeating: 0, count: n)
            for i in 0..<m {
                for j in 0..<n {
                    b[j] -= J[i * n + j] * r[i]
                    for k in 0..<n { A[j * n + k] += J[i * n + j] * J[i * n + k] }
                }
            }
            for j in 0..<n { A[j * n + j] *= (1 + lambda) }
            guard let d = solve6(A, b) else { break }
            var xn = x
            for j in 0..<n { xn[j] += d[j] }
            let en = rms(residuals(xn))
            if en < err { x = xn; err = en; lambda = max(lambda * 0.5, 1e-5) }
            else { lambda *= 4; if lambda > 1e4 { break } }
            if err < 0.3 { break }
        }

        let V = SIMD3<Float>(x[3], x[4], x[5])
        guard V.x.isFinite, V.y.isFinite, V.z.isFinite else { return nil }
        return (SIMD3<Float>(x[0], x[1], x[2]), V, err)
    }

    /// Full-flight screen path: fit as in `solve`, then integrate the flight
    /// forward (ballistic) and project every step back to pixels — the
    /// physically-shaped continuation of the observed stub (never the
    /// screen-space-quadratic trap). Returns [] when the fit fails the
    /// physical gates. Points are (u,v) pixels with the observation clock.
    static func projectedFlight(_ obs: [Observation], camera: Camera,
                                stepSeconds: Float = 1.0 / 30) -> [(u: Float, v: Float, t: Float)] {
        guard let state = solveState(obs, camera: camera) else { return [] }
        let g = simd_normalize(camera.gravityDir) * 9.8
        let up = -simd_normalize(camera.gravityDir)
        let h0 = simd_dot(state.p0, up)
        var out: [(Float, Float, Float)] = []
        var t: Float = 0
        while t < 10 {
            let P = state.p0 + state.v * t + 0.5 * g * t * t
            let z = max(P.z, 0.05)
            out.append((camera.fx * P.x / z + camera.cx,
                        camera.fy * P.y / z + camera.cy, t))
            if t > 0.5, simd_dot(P, up) < h0 { break }   // back to launch height
            t += stepSeconds
        }
        return out
    }

    /// Bounded fit for ESTIMATED-intrinsics clips (imported videos): free
    /// Gauss-Newton collapses to a slow-near-ball solution on rising-only
    /// observations (validated offline). Instead: anchor the launch on the
    /// first observation's ray at `anchorZ` (pose-height scale, doc §4.3) and
    /// grid-search physically-bounded (speed, launch, azimuth).
    /// `teePixel`: address ball pixel — when present the LAUNCH POINT is
    /// anchored there (at depth anchorZ) and the launch time t0 (≤ 0,
    /// relative to the first observation) becomes a grid dimension. Anchoring
    /// the first DETECTION instead squeezes the geometry: at driver speed the
    /// ball is already ~3 m downrange when YOLO first sees it, so pinning
    /// that point at tee depth collapses the arc (offline doc S3: 击球帧自由).
    /// `t0Hint`: measured launch time (≤ 0, relative to obs[0]) from an
    /// independent witness (motion pass near-tee mover at impact). Pinning
    /// t0 collapses the fit's most degenerate dimension.
    static func solveBoundedState(_ obs: [Observation], camera: Camera, anchorZ: Float,
                                  teePixel: (u: Float, v: Float)? = nil,
                                  t0Hint: Float? = nil)
        -> (p0: SIMD3<Float>, v: SIMD3<Float>, err: Float, t0: Float)? {
        guard obs.count >= 5, anchorZ > 1, anchorZ < 15 else { return nil }
        let g = simd_normalize(camera.gravityDir) * 9.8
        let anchorUV = teePixel ?? (obs[0].u, obs[0].v)
        let d0 = simd_normalize(SIMD3<Float>((anchorUV.u - camera.cx) / camera.fx,
                                             (anchorUV.v - camera.cy) / camera.fy, 1))
        let p0 = d0 * (anchorZ / max(d0.z, 0.1))
        // First detection can lag launch by up to ~0.3 s (dim ball, motion
        // blur) — a too-narrow grid pins t0 at its edge and poisons speed.
        let t0Grid: [Float]
        if let hint = t0Hint {
            t0Grid = [min(0, hint - 0.033), min(0, hint), min(0, hint + 0.033)]
        } else {
            t0Grid = teePixel != nil ? [-0.30, -0.225, -0.15, -0.075, 0] : [0]
        }
        let up = -simd_normalize(camera.gravityDir)
        // forward = camera +z projected ⟂ up; right = forward × up
        var fwd = SIMD3<Float>(0, 0, 1) - simd_dot(SIMD3<Float>(0, 0, 1), up) * up
        fwd = simd_normalize(fwd)
        let right = simd_normalize(simd_cross(fwd, up))
        func rms(_ v: SIMD3<Float>, _ t0: Float) -> Float {
            var s: Float = 0
            for o in obs {
                let dt = o.t - t0
                let P = p0 + v * dt + 0.5 * g * dt * dt
                let z = max(P.z, 0.05)
                let du = camera.fx * P.x / z + camera.cx - o.u
                let dv = camera.fy * P.y / z + camera.cy - o.v
                s += du * du + dv * dv
            }
            return (s / Float(obs.count * 2)).squareRoot()
        }
        func velocity(_ sp: Float, _ la: Float, _ az: Float) -> SIMD3<Float> {
            let vh = sp * cos(la)
            return up * (sp * sin(la)) + fwd * (vh * cos(az)) + right * (vh * sin(az))
        }
        var best: (v: SIMD3<Float>, err: Float, t0: Float)? = nil
        var sGrid: [Float] = [28, 36, 44, 52, 60, 68]
        var laGrid = stride(from: Float(10), through: 42, by: 6).map { $0 * .pi / 180 }
        // ±16° too narrow (a "behind the golfer" DTL shot flies ~23° to the side
        // and clips the boundary → speed/launch poisoned). But ±40 was too wide —
        // let degenerate flat-sideways solutions in on device. ±28 covers the side
        // shot with margin; refine keeps it sharp.
        var azGrid = stride(from: Float(-28), through: 28, by: 7).map { $0 * .pi / 180 }
        var tGrid = t0Grid
        for _ in 0..<3 {                                  // grid → refine ×2
            var top: (s: Float, la: Float, az: Float, t0: Float, err: Float)? = nil
            for sp in sGrid { for la in laGrid { for az in azGrid { for t0 in tGrid {
                let e = rms(velocity(sp, la, az), t0)
                if top == nil || e < top!.err { top = (sp, la, az, t0, e) }
            }}}}
            guard let t = top else { return nil }
            best = (velocity(t.s, t.la, t.az), t.err, t.t0)
            sGrid  = [max(22, t.s - 5), t.s, min(75, t.s + 5)]
            laGrid = [max(8 * .pi / 180, t.la - 0.05), t.la, min(45 * .pi / 180, t.la + 0.05)]
            azGrid = [t.az - 0.04, t.az, t.az + 0.04]
            // A hinted t0 is a MEASUREMENT (witness ±1 frame) — refine must
            // not wander off it (it drifted -0.133 → -0.226 and re-found the
            // slow branch). Only the unhinted grid re-centers.
            tGrid  = t0Hint != nil ? t0Grid
                   : (t0Grid.count > 1 ? [min(0, t.t0 - 0.03), t.t0, min(0, t.t0 + 0.03)] : [0])
        }
        guard let b = best else { return nil }
        return (p0, b.v, b.err, b.t0)
    }

    /// Effective drag + lift coefficients for a launch angle, which stands in
    /// for spin (more loft ≈ more backspin). NOT fit degrees of freedom — a
    /// prior, so the arc shape splits by club without the solver getting a knob
    /// to overfit with.
    ///
    /// Anchored on measured ball flights and linearly interpolated between:
    ///
    ///   10.9° → Cd 0.21, Cl 0.16   PGA driver, 2686 rpm
    ///   16.3° → Cd 0.35, Cl 0.37   PGA 7-iron, 7100 rpm
    ///   20.0° → Cd 0.33, Cl 0.31   amateur 7-iron
    ///
    /// These are EFFECTIVE constants — fitted so this simplified model (no spin
    /// decay, no Reynolds dependence) reproduces the real carry/apex/hang, not
    /// measured aerodynamic properties. Cd 0.35 is high for a real golf ball; it
    /// is absorbing what the model leaves out.
    ///
    /// Cd used to be pinned at 0.25 with Cl bucketed 0.18/0.22/0.27, and every
    /// ball rose too little: apex came in 14–26 % low (7-iron 23.8 m vs a real
    /// 32 m) while carry landed within 9 %, so the arcs read flat and dropped
    /// early. Spin is the driver of both coefficients and it varies 2.6× between
    /// driver and 7-iron — a 1.2× spread in Cl alone could never express that,
    /// and a fixed Cd made lift and distance impossible to satisfy at once.
    /// Lowering gravity would lift the apex too, but it would inflate a carry
    /// that is already correct, and g is the one quantity here we know exactly.
    static func aeroForLaunch(_ launchDeg: Float) -> (cd: Float, cl: Float) {
        let anchors: [(deg: Float, cd: Float, cl: Float)] = [
            (10.9, 0.21, 0.16),
            (16.3, 0.35, 0.37),
            (20.0, 0.33, 0.31),
        ]
        if launchDeg <= anchors[0].deg { return (anchors[0].cd, anchors[0].cl) }
        if launchDeg >= anchors[anchors.count - 1].deg {
            let a = anchors[anchors.count - 1]; return (a.cd, a.cl)
        }
        for i in 0..<(anchors.count - 1) {
            let a = anchors[i], b = anchors[i + 1]
            if launchDeg >= a.deg && launchDeg <= b.deg {
                let u = (launchDeg - a.deg) / (b.deg - a.deg)
                return (a.cd + u * (b.cd - a.cd), a.cl + u * (b.cl - a.cl))
            }
        }
        return (anchors[0].cd, anchors[0].cl)
    }

    private static func integrateFlight(p0: SIMD3<Float>, v0: SIMD3<Float>, camera: Camera,
                                        stepSeconds: Float) -> [(P: SIMD3<Float>, t: Float)] {
        let g = simd_normalize(camera.gravityDir) * 9.8
        let up = -simd_normalize(camera.gravityDir)
        let h0 = simd_dot(p0, up)
        let kAir: Float = 0.5 * 1.2 * 1.432e-3 / 0.0459   // ½ρA/m (r 21.35mm, 45.9g)
        let sp0 = simd_length(v0)
        let launchDeg = asin(max(-1, min(1, simd_dot(v0, up) / max(sp0, 1e-6)))) * 180 / .pi
        let (cd, cl) = aeroForLaunch(launchDeg)
        var P = p0, V = v0
        var t: Float = 0
        let dt: Float = 1.0 / 240
        var nextSample: Float = 0
        var out: [(P: SIMD3<Float>, t: Float)] = []
        while t < 10 {
            if t >= nextSample {
                out.append((P, t))
                nextSample += stepSeconds
                if t > 0.5, simd_dot(P, up) < h0 { break }   // landed
            }
            let sp = simd_length(V)
            var a = g - kAir * cd * sp * V
            if sp > 1 {
                let vh = V / sp
                var l = up - simd_dot(up, vh) * vh           // lift ⟂ V, upward
                let ln = simd_length(l)
                if ln > 1e-3 { l /= ln; a += kAir * cl * sp * sp * l }
            }
            V += a * dt
            P += V * dt
            t += dt
        }
        return out
    }

    /// Full-flight projection from an already-solved state, offline-validated
    /// physics. IMPORTANT: fit with plain sensor gravity, pass the ground-
    /// plane pitch only through THIS camera's gravityDir — tilting gravity
    /// inside the bounded grid shifts its near-degenerate minimum to a slow
    /// solution (swing_002 regression: 60 → 36 m/s). The path starts at the
    /// solved launch point (the tee when the fit was tee-anchored); sample
    /// times are in the OBSERVATION time base (launch = st.t0 ≤ 0).
    static func projectedFlight(from st: (p0: SIMD3<Float>, v: SIMD3<Float>, err: Float, t0: Float),
                                camera: Camera,
                                stepSeconds: Float = 1.0 / 30) -> [(u: Float, v: Float, t: Float)] {
        var out: [(Float, Float, Float)] = []
        for s in integrateFlight(p0: st.p0, v0: st.v, camera: camera, stepSeconds: stepSeconds) {
            let z = max(s.P.z, 0.05)
            out.append((camera.fx * s.P.x / z + camera.cx,
                        camera.fy * s.P.y / z + camera.cy,
                        s.t + st.t0))
        }
        return out
    }

    /// Metrics from a solved state. Carry comes from the drag+lift
    /// integration, not the vacuum formula (vacuum overshoots ~10%).
    /// `camera` here may carry the pitched gravity (see projectedFlight).
    static func metrics(from st: (p0: SIMD3<Float>, v: SIMD3<Float>, err: Float, t0: Float),
                        camera: Camera) -> BallFlight {
        let up = -simd_normalize(camera.gravityDir)
        let speed = simd_length(st.v)
        let vUp = simd_dot(st.v, up)
        let launch = asin(max(-1, min(1, vUp / speed))) * 180 / .pi
        let path = integrateFlight(p0: st.p0, v0: st.v, camera: camera, stepSeconds: 1.0 / 30)
        let d = (path.last?.P ?? st.p0) - st.p0
        let carry = simd_length(d - simd_dot(d, up) * up)
        return BallFlight(speedMps: speed, launchAngleDeg: launch,
                          carryMeters: carry, reprojErrPx: st.err)
    }

    /// Convenience: bounded fit + metrics with one camera (self-test path).
    static func solveBounded(_ obs: [Observation], camera: Camera, anchorZ: Float) -> BallFlight? {
        guard let st = solveBoundedState(obs, camera: camera, anchorZ: anchorZ) else { return nil }
        return metrics(from: st, camera: camera)
    }

    /// The internal fit (P0, V) behind `solve` — shared implementation.
    private static func solveState(_ obs: [Observation], camera: Camera)
        -> (p0: SIMD3<Float>, v: SIMD3<Float>)? {
        guard solve(obs, camera: camera) != nil,
              let st = fitRaw(obs, camera: camera) else { return nil }
        return (st.p0, st.v)
    }

    private static func rms(_ r: [Float]) -> Float {
        guard !r.isEmpty else { return .infinity }
        return (r.reduce(0) { $0 + $1 * $1 } / Float(r.count)).squareRoot()
    }

    /// Gaussian elimination for the 6×6 damped normal equations.
    private static func solve6(_ A0: [Float], _ b0: [Float]) -> [Float]? {
        let n = 6
        var A = A0, b = b0
        for col in 0..<n {
            var piv = col
            for r in (col + 1)..<n where abs(A[r * n + col]) > abs(A[piv * n + col]) { piv = r }
            guard abs(A[piv * n + col]) > 1e-9 else { return nil }
            if piv != col {
                for k in 0..<n { A.swapAt(col * n + k, piv * n + k) }
                b.swapAt(col, piv)
            }
            let d = A[col * n + col]
            for r in (col + 1)..<n {
                let f = A[r * n + col] / d
                if f == 0 { continue }
                for k in col..<n { A[r * n + k] -= f * A[col * n + k] }
                b[r] -= f * b[col]
            }
        }
        var xres = [Float](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = b[row]
            for k in (row + 1)..<n { s -= A[row * n + k] * xres[k] }
            xres[row] = s / A[row * n + row]
        }
        return xres
    }
}

#if DEBUG
/// BALLFIT=1 — synthetic roundtrip proof of the solver: generate a known 3D
/// flight, project through known intrinsics with pixel noise, fit, compare.
enum BallFlightSelfTest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["BALLFIT"] == "1" else { return }
        let cam = BallFlightSolver.Camera(fx: 1600, fy: 1600, cx: 540, cy: 960)
        let P0 = SIMD3<Float>(-0.4, 0.9, 3.2)       // tee: left-low, 3.2 m out
        let V  = SIMD3<Float>(6.0, -11.0, 18.0)     // 22.2 m/s launch
        let g  = SIMD3<Float>(0, 9.8, 0)
        var obs: [BallFlightSolver.Observation] = []
        var seed: UInt64 = 42
        func noise() -> Float {                      // ±0.5 px deterministic
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Float(seed % 1000) / 1000 - 0.5)
        }
        for i in 0..<16 {
            let t = Float(i) / 30
            let P = P0 + V * t + 0.5 * g * t * t
            obs.append(.init(u: cam.fx * P.x / P.z + cam.cx + noise(),
                             v: cam.fy * P.y / P.z + cam.cy + noise(),
                             t: t))
        }
        guard let fit = BallFlightSolver.solve(obs, camera: cam) else {
            NSLog("[ballfit] FAIL: no solution"); return
        }
        let trueSpeed = simd_length(V)
        let speedErr = abs(fit.speedMps - trueSpeed) / trueSpeed * 100
        let up = SIMD3<Float>(0, -1, 0)
        let trueLaunch = asin(simd_dot(V, up) / trueSpeed) * 180 / Float.pi
        NSLog("[ballfit] true speed=%.1f fit=%.1f (err %.1f%%) | true launch=%.1f° fit=%.1f° | reproj=%.2fpx | %@",
              trueSpeed, fit.speedMps, speedErr, trueLaunch, fit.launchAngleDeg,
              fit.reprojErrPx, speedErr < 5 ? "PASS" : "FAIL")
    }
}
#endif
