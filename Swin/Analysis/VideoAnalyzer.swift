import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import Observation

/// Off-camera analysis: scan an existing video, extract pose per frame via
/// the same PoseService used live, then run event detection + metrics.
@Observable
final class VideoAnalyzer: @unchecked Sendable {
    enum Status: Sendable, Equatable {
        case idle
        case extracting(progress: Double)   // 0…1
        case analyzing                       // events + metrics on full sequence
        case done
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var report: SwingReport?

    private let poseService: PoseService
    private let eventDetector: any EventDetector

    init(poseService: PoseService, eventDetector: any EventDetector) {
        self.poseService = poseService
        self.eventDetector = eventDetector
    }

    /// Bring the analyzer back to a clean .idle state. UploadView calls
    /// this after the user closes the result sheet so a second upload of
    /// the same file picks up cleanly instead of getting stuck on a stale
    /// "Analysis complete" card.
    func reset() {
        status = .idle
        report = nil
    }

    /// `viewpoint` + `handedness` come from the upload picker. handedness (if
    /// given) OVERRIDES the auto-detected value — the user knows their own hand
    /// and detection can be wrong from some angles. viewpoint is stored on the
    /// report so downstream knows which faults/visuals are reliable.
    func analyze(url: URL, viewpoint: Viewpoint = .downTheLine, handedness: String? = nil,
                 isImported: Bool = false) async {
        await MainActor.run {
            self.status = .extracting(progress: 0)
            self.report = nil
        }

        let asset = AVURLAsset(url: url)
        let track: AVAssetTrack
        let duration: CMTime
        let frameRate: Float
        let preferredTransform: CGAffineTransform
        let naturalSize: CGSize
        do {
            guard let t = try await asset.loadTracks(withMediaType: .video).first else {
                await fail("No video track in file")
                return
            }
            track = t
            duration = try await asset.load(.duration)
            frameRate = try await track.load(.nominalFrameRate)
            preferredTransform = try await track.load(.preferredTransform)
            naturalSize = try await track.load(.naturalSize)
        } catch {
            await fail("Cannot load asset: \(error.localizedDescription)")
            return
        }
        let totalFrames = max(1, Int(Float(CMTimeGetSeconds(duration)) * frameRate))
        let cgOrientation = Self.cgImageOrientation(for: preferredTransform)
        // Compute the oriented frame size — swap width/height for portrait videos
        // shot in landscape sensor (orientation .right/.left). PoseOverlay uses
        // this to scale normalized keypoints back to view-space pixels.
        let videoSize: CGSize
        switch cgOrientation {
        case .right, .left, .rightMirrored, .leftMirrored:
            videoSize = CGSize(width: naturalSize.height, height: naturalSize.width)
        default:
            videoSize = naturalSize
        }
        print("[VideoAnalyzer] orientation=\(cgOrientation.rawValue) "
              + "natural=\(Int(naturalSize.width))×\(Int(naturalSize.height)) "
              + "oriented=\(Int(videoSize.width))×\(Int(videoSize.height))")

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            await fail("Reader init failed: \(error.localizedDescription)")
            return
        }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        if reader.canAdd(output) { reader.add(output) }
        if !reader.startReading() {
            await fail("Reader failed to start: \(reader.error?.localizedDescription ?? "?")")
            return
        }

        // Stage timing probe — find the latency bottleneck (upload → result).
        let perfT0 = CFAbsoluteTimeGetCurrent()
        var perfLast = perfT0
        func perf(_ label: String) {
            let now = CFAbsoluteTimeGetCurrent()
            print(String(format: "[perf] %@ %.2fs (total %.2fs)", label, now - perfLast, now - perfT0))
            perfLast = now
        }
        var poses: [PoseFrame] = []
        var frameCount = 0
        while let buf = output.copyNextSampleBuffer() {
            // Use the orientation derived from the track's preferredTransform so
            // both portrait phone recordings AND landscape online clips work.
            let pose = poseService.extractSync(buf, cgOrientation: cgOrientation)
                ?? PoseFrame(
                    timestamp: CMSampleBufferGetPresentationTimeStamp(buf),
                    keypoints: [SIMD2<Float>](repeating: .zero, count: PoseFrame.jointCount),
                    confidences: [Float](repeating: 0, count: PoseFrame.jointCount)
                )
            poses.append(pose)
            frameCount += 1
            if frameCount % 5 == 0 {
                let prog = min(1.0, Double(frameCount) / Double(totalFrames))
                await MainActor.run { self.status = .extracting(progress: prog) }
            }
        }
        if reader.status == .failed {
            await fail("Reader error: \(reader.error?.localizedDescription ?? "?")")
            return
        }

        perf("pose extraction (\(poses.count) frames)")
        await MainActor.run { self.status = .analyzing }
        var events = eventDetector.detect(poses)
        // User-supplied handedness overrides detection (more reliable).
        if let h = handedness {
            events = SwingEvents(frames: events.frames, handedness: h == "left" ? .left : .right)
        }
        let calc = MetricsCalculator()
        let metrics = calc.compute(poses: poses, events: events)
        let perEvent = calc.computePerEvent(poses: poses, events: events)
        let dynamics = calc.computeDynamics(poses: poses, events: events, viewpoint: viewpoint)
        perf("events + metrics")

        // Clubhead track pass (distilled on-device detector, ClubDetectYOLO11n).
        // Non-blocking: report ships without it if the model is missing or
        // fewer than 3 confident clubheads were found.
        var clubTrack: ClubTrack? = nil
        if let clubDetector = try? ClubDetectService() {
            clubTrack = await clubDetector.detect(in: url, orientation: cgOrientation)
            if let ct = clubTrack {
                print("[VideoAnalyzer] ✅ club track: \(ct.points.count) pts, coverage=\(String(format: "%.2f", ct.coverage))")
            } else {
                print("[VideoAnalyzer] ❌ no club track")
            }
        }
        perf("club detect")

        // Optional ball trajectory pass — scans frames after Impact (or just
        // the middle of the clip if Impact wasn't detected). Doesn't block the
        // report from finishing if it fails.
        var ballTraj: BallTrajectory? = nil
        var ballMergeDebug: [String: Any] = [:]
        var launchWitness: (x: Float, y: Float, t: Double)? = nil
        if frameRate > 0 {
            let impactFrameOpt = events.frame(for: .impact)
            let scanFromFrame = impactFrameOpt ?? max(0, poses.count / 2)
            // Impact time must be the REAL decoded timestamp of that pose frame
            // — the observed ball points carry real sample PTS, so a computed
            // frame/fps impact drifts the whole overlay off the video (the
            // "轨迹和时间戳没对齐" bug). Both now share one media-time anchor.
            let impactSec: Double = poses.indices.contains(scanFromFrame)
                ? CMTimeGetSeconds(poses[scanFromFrame].timestamp)
                : Double(scanFromFrame) / Double(frameRate)
            print("[VideoAnalyzer] scanning ball trajectory from frame \(scanFromFrame) "
                  + "(\(String(format: "%.3f", impactSec))s) "
                  + "[impact \(impactFrameOpt.map(String.init) ?? "n/a")]")
            // Top rung: TrackNet (U-Net heatmap) — the golf-flight detector
            // that tracks the post-impact ball where Vision/YOLO lose it (it
            // sees the ball per-frame, no parabola-sweep requirement). Runs as
            // a burst over the post-impact window; falls back to the old ladder.
            if let tracknet = try? TrackNetBallDetector() {
                ballTraj = await tracknet.detect(
                    in: url,
                    impactFrameIndex: scanFromFrame,
                    impactSeconds: impactSec,
                    startSeconds: max(0, impactSec - 0.05),
                    windowSeconds: 1.2,   // flight is ~0.5 s post-impact — a 2 s window
                                          // just burns decode + inference on empty frames
                    orientation: cgOrientation,
                    // Veto chains riding the follow-through clubhead. Without
                    // this the club's long smooth arc outscores the ball and
                    // the tee back-extrapolates off-frame (V2).
                    clubTrack: clubTrack?.points.map { (x: $0.x, y: $0.y, t: $0.timeSeconds) })
                if let t = ballTraj {
                    print("[VideoAnalyzer] ✅ TrackNet ball: \(t.points.count) pts, conf=\(t.confidence)")
                }
            }
            if ballTraj == nil {
                let detector = BallTrajectoryDetector()
                ballTraj = await detector.detect(
                    in: url,
                    impactFrameIndex: scanFromFrame,
                    startSeconds: max(0, impactSec - 0.1),
                    windowSeconds: 2.0,
                    fps: Double(frameRate),
                    orientation: cgOrientation
                )
                if let t = ballTraj {
                    print("[VideoAnalyzer] ✅ ball trajectory: \(t.points.count) pts, conf=\(t.confidence)")
                } else {
                    print("[VideoAnalyzer] ❌ Vision trajectory empty — trying YOLO ball fallback")
                    if let yolo = try? BallDetectService() {
                        ballTraj = await yolo.detect(
                            in: url,
                            impactFrameIndex: scanFromFrame,
                            startSeconds: max(0, impactSec - 0.1),
                            windowSeconds: 2.0,
                            orientation: cgOrientation)
                        if let t = ballTraj {
                            print("[VideoAnalyzer] ✅ YOLO ball fallback: \(t.points.count) pts, conf=\(t.confidence)")
                        } else {
                            print("[VideoAnalyzer] ❌ YOLO ball fallback: nothing")
                        }
                    }
                }
            }
            // Motion-based detection ALWAYS runs (not just as a fallback):
            // it catches the frames right after impact that YOLO misses, and
            // those earliest points constrain the launch geometry most — the
            // fit on YOLO-only ascent points sits on a flat error surface and
            // hops between minima (47 vs 60 m/s on the same clip).
            var corridor: CGPoint? = nil
            if let ct = clubTrack, !ct.points.isEmpty {
                let early = ct.points.prefix(5)
                let mx = early.map { CGFloat($0.x) }.sorted()[early.count / 2]
                let my = early.map { CGFloat($0.y) }.sorted()[early.count / 2]
                corridor = CGPoint(x: mx, y: my)
            }
            // Skip the motion pass (decode + 321-candidate chaining ≈ seconds)
            // when TrackNet already produced a solid flight — its points cover
            // the early frames motion was there to backfill. Big latency win.
            let motionDet = MotionBallDetector()
            let motionTraj = (ballTraj?.points.count ?? 0) >= 10 ? nil : await motionDet.detect(
                in: url,
                impactFrameIndex: scanFromFrame,
                startSeconds: max(0, impactSec - 0.05),
                windowSeconds: 1.2,
                orientation: cgOrientation,
                corridorCenter: corridor)
            // Witness = earliest near-tee mover that is NOT the clubhead
            // (the club sweeps the corridor right at impact and is brighter
            // than the ball — it faked a witness 1 frame early, 0.06 right).
            func clubheadAt(_ t: Double) -> (x: Float, y: Float)? {
                clubTrack?.points
                    .min { abs($0.timeSeconds - t) < abs($1.timeSeconds - t) }
                    .flatMap { abs($0.timeSeconds - t) < 0.06 ? (x: $0.x, y: $0.y) : nil }
            }
            launchWitness = motionDet.earlyTeeCandidates.first { c in
                guard let ch = clubheadAt(c.t) else { return true }
                return hypotf(c.x - ch.x, c.y - ch.y) > 0.05
            }
            if let w = launchWitness {
                print("[VideoAnalyzer] 🎯 witness after club veto: (\(w.x), \(w.y)) t=\(w.t)")
            }
            if let m = motionTraj {
                print("[VideoAnalyzer] ✅ motion ball pass: \(m.points.count) pts")
            }
            ballMergeDebug = ["yolo": ballTraj?.points.count ?? 0,
                              "motion": motionTraj?.points.count ?? 0,
                              "corridor": corridor.map { [Double($0.x), Double($0.y)] } ?? []]
            if ballTraj == nil {
                ballTraj = motionTraj
            } else if let m = motionTraj, var t = ballTraj {
                // Merge: motion points fill the early gap; drop near-duplicates
                // (< 1/60 s apart). Time bases align — both are seconds from
                // each detector's own first point near impact, so re-express
                // motion times against the YOLO base via overlap matching:
                // nearest-pair offset (median), robust to a frame of skew.
                let offsets = m.points.compactMap { mp -> Double? in
                    t.points.min(by: {
                        abs($0.timeOffsetSeconds - mp.timeOffsetSeconds)
                            < abs($1.timeOffsetSeconds - mp.timeOffsetSeconds)
                    }).map { near in
                        hypot(Double(near.x - mp.x), Double(near.y - mp.y)) < 0.03
                            ? near.timeOffsetSeconds - mp.timeOffsetSeconds : nil
                    } ?? nil
                }.sorted()
                let dt = offsets.isEmpty ? 0 : offsets[offsets.count / 2]
                var merged = t.points
                for mp in m.points {
                    let mt = mp.timeOffsetSeconds + dt
                    if !merged.contains(where: { abs($0.timeOffsetSeconds - mt) < 1.0 / 60 }) {
                        merged.append(.init(x: mp.x, y: mp.y, timeOffsetSeconds: mt))
                    }
                }
                merged.sort { $0.timeOffsetSeconds < $1.timeOffsetSeconds }
                // Re-zero so the earliest observation is t=0 (fit convention).
                if let t0 = merged.first?.timeOffsetSeconds, t0 < 0 {
                    merged = merged.map { .init(x: $0.x, y: $0.y,
                                                timeOffsetSeconds: $0.timeOffsetSeconds - t0) }
                }
                print("[VideoAnalyzer] 🔗 merged obs: yolo \(t.points.count) + motion \(m.points.count) → \(merged.count) (dt \(String(format: "%.3f", dt)))")
                t.points = merged
                ballTraj = t
            }
        }

        perf("ball trajectory (TrackNet/motion/YOLO)")
        // Metric ball flight + full-arc prediction. Real-device recordings
        // supply true intrinsics/gravity (camera_intrinsics_latest.json);
        // imported clips fall back to a 26 mm-equivalent estimate — arc shape
        // stays physical, absolute numbers are looser (doc §S5 bounds).
        var ballFlight: BallFlight? = nil
        if let traj = ballTraj, traj.points.count >= 5 {
            // Real impact media time (same anchor the observed points use) so
            // the predicted arc lands back on the video clock.
            let impactSec: Double = poses.indices.contains(traj.impactFrameIndex)
                ? CMTimeGetSeconds(poses[traj.impactFrameIndex].timestamp)
                : Double(traj.impactFrameIndex) / Double(max(frameRate, 1))
            var cam = BallFlightSolver.Camera(
                fx: Float(videoSize.height) * 0.72,
                fy: Float(videoSize.height) * 0.72,
                cx: Float(videoSize.width) / 2,
                cy: Float(videoSize.height) / 2)
            var hasMeasuredGravity = false
            // Imported clips must NOT reuse a device recording's stale
            // intrinsics/gravity (it's for a different camera pose) — that set
            // hasMeasuredGravity=true and skipped the ground-plane pitch, so the
            // arc fell to the foreground. Imported → always estimate pitch.
            if !isImported,
               let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let data = try? Data(contentsOf: docs.appendingPathComponent("camera_intrinsics_latest.json")),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let fx = obj["fx"] as? Double, let fy = obj["fy"] as? Double,
               let cx = obj["cx"] as? Double, let cy = obj["cy"] as? Double {
                cam = BallFlightSolver.Camera(fx: Float(fx), fy: Float(fy),
                                              cx: Float(cx), cy: Float(cy))
                if let gv = obj["gravity"] as? [Double], gv.count == 3 {
                    cam.gravityDir = SIMD3<Float>(Float(gv[0]), Float(gv[1]), Float(gv[2]))
                    hasMeasuredGravity = true
                }
            }
            // Imported clips (no IMU): GeoCalib single-image calibration →
            // ground-plane pitch + focal from ONE frame. Runs once (~0.3–0.8 s
            // ANE). Replaces the hand-rolled horizon estimate that kept failing
            // on night/rear-view (the "落点栽前景" bug) — GeoCalib is the
            // learned, robust source of the horizon.
            var geoPitch: Float? = nil
            if isImported, !hasMeasuredGravity, let gc = try? GeoCalibService(),
               let cal = await gc.calibrate(in: url, atSeconds: impactSec,
                                            videoSize: videoSize, orientation: cgOrientation) {
                cam = BallFlightSolver.Camera(fx: cal.focalPx, fy: cal.focalPx,
                                              cx: cam.cx, cy: cam.cy)
                geoPitch = cal.pitchRad
                print("[VideoAnalyzer] 📐 GeoCalib: horizon \(String(format: "%.3f", cal.horizonY)), pitch \(String(format: "%.1f", cal.pitchRad * 180 / .pi))°, focal \(Int(cal.focalPx))")
            }
            // Ground line = lowest ankle at address (feet on the mat). Both tee
            // branches below measure against it.
            let addrFrame = min(poses.count - 1, max(0, events.frame(for: .address) ?? 0))
            let groundY = max(poses[addrFrame].keypoints[Joint.leftAnkle].y,
                              poses[addrFrame].keypoints[Joint.rightAnkle].y)

            var teePixel: (u: Float, v: Float)? = nil
            // (1) Chain head already on the ground → TrackNet caught the address
            // ball itself, and the flight is the same object continuing. That IS
            // the tee; every other branch here is a proxy for it.
            if let head = traj.points.first, head.y >= groundY - 0.05 {
                teePixel = (head.x * Float(videoSize.width), head.y * Float(videoSize.height))
                print("[VideoAnalyzer] 🏌️ tee = chain head on ground (\(String(format: "%.3f,%.3f", head.x, head.y)))")
            }
            // (2) Tee pixel = address clubhead (median of the early track). Used
            // as the fit's LAUNCH ANCHOR (with launch time free) — anchoring
            // the first detection instead collapses the arc (ball is already
            // ~3 m downrange when YOLO first sees it).
            if teePixel == nil, let ct = clubTrack, !ct.points.isEmpty {
                let early = ct.points.prefix(5)
                let ux = early.map(\.x).sorted()[early.count / 2]
                let uy = early.map(\.y).sorted()[early.count / 2]
                teePixel = (ux * Float(videoSize.width), uy * Float(videoSize.height))
            }
            // No club track → recover the launch ORIGIN (the address ball, which
            // doesn't move address→impact — user: "轨迹起点一定是 address 那颗球").
            // Two-stage: (1) back-extrapolate the flight line to the ground for a
            // REFERENCE point, then (2) snap onto the real mat ball via YOLO — the
            // detection nearest that reference. The reference guides YOLO past the
            // many static range balls; YOLO gives the exact pixel the line-only
            // extrapolation can't (its early velocity is already curving).
            // The ball is not in flight before impact, so the launch direction
            // must be measured from points that are genuinely post-impact. A
            // pre-impact chain point in mid-air is the CLUB: TrackNet fires on
            // the shaft's motion blur, and those points sit at a near-constant
            // height, driving vy → 0. Measured offline on a 1264×720 night clip:
            // the shaft pair gave vy = -0.0017/frame → back = -83 frames → tee at
            // x = -7229 px (offscreen). Dropping them: vy = -0.0764 → back = -3.6
            // → tee x = 811 px, against a real address ball at 802 px.
            let flightPts = traj.points.filter { $0.timeOffsetSeconds >= 0 }
            if teePixel == nil, flightPts.count >= 2 {
                let p0 = flightPts[0], p1 = flightPts[1]
                let dt = Float(p1.timeOffsetSeconds - p0.timeOffsetSeconds)
                let vy = (p1.y - p0.y) / max(dt, 1e-3)
                if dt > 0, vy < -0.01 {                       // ball rising (y decreasing)
                    let af = addrFrame
                    let vx = (p1.x - p0.x) / dt
                    let back = (groundY - p0.y) / vy          // Δt back to groundY (<0)
                    let refX = p0.x + vx * back
                    let ref = CGPoint(x: CGFloat(refX), y: CGFloat(groundY))
                    // (2) snap to the YOLO static ball nearest the reference
                    let addrSec = CMTimeGetSeconds(poses[af].timestamp)
                    if poses.count > 5, let ballDet = try? BallDetectService(),
                       let ball = await ballDet.staticBall(in: url, atSeconds: addrSec, near: ref,
                                                           orientation: cgOrientation) {
                        teePixel = (Float(ball.x) * Float(videoSize.width),
                                    Float(ball.y) * Float(videoSize.height))
                        print("[VideoAnalyzer] 🏌️ address ball (YOLO snap→ref \(String(format: "%.3f,%.3f", refX, groundY))) → tee(\(String(format: "%.3f,%.3f", ball.x, ball.y)))")
                    } else {
                        teePixel = (refX * Float(videoSize.width), groundY * Float(videoSize.height))
                        print("[VideoAnalyzer] 🏌️ tee by flight-extrapolation → (\(refX), \(groundY))")
                    }
                }
            }
            // Same impact gate on the fit itself: pre-impact points are the club
            // (or the static address ball, which the tee branch already used) —
            // as flight observations they only drag the solver. The offline run
            // fed them in and the fit failed outright.
            var obs = flightPts.map {
                BallFlightSolver.Observation(u: $0.x * Float(videoSize.width),
                                             v: $0.y * Float(videoSize.height),
                                             t: Float($0.timeOffsetSeconds))
            }
            // Absolute media time that obs `t = 0` maps to. Threaded through the
            // re-zeroing below so the predicted arc can be put back on the video
            // clock (predicted point media time = obsAbsZero + fitT).
            var obsAbsZero = traj.firstObsMediaTime ?? impactSec
            // Leading-obs hygiene: drop the head ONLY if it sits on the tee
            // (static address ball glued onto the flight chain). A head point
            // AWAY from the tee is the most valuable observation there is —
            // dropping it on a mere time-gap heuristic degraded the fit badly
            // (47 → 28 m/s, verified), because chain dropout gaps are normal.
            if let tee = teePixel, obs.count >= 6 {
                while let head = obs.first, obs.count >= 6,
                      hypot(head.u - tee.u, head.v - tee.v)
                          < Float(videoSize.height) * 0.015 {
                    obs.removeFirst()
                    print("[VideoAnalyzer] 🧹 dropped static tee obs at head")
                }
                if let t0 = obs.first?.t, t0 > 0 {
                    obs = obs.map { .init(u: $0.u, v: $0.v, t: $0.t - t0) }
                    obsAbsZero += Double(t0)
                }
            }
            // Scale anchor: person pixel height at address + profile height
            // (pose-height geometry, pipeline doc §4.3) → tee depth.
            var anchorZ: Float = 3.5
            if poses.count > 10 {
                let sample = poses.prefix(12)
                var spans: [Float] = []
                for p in sample {
                    let ys = p.keypoints.enumerated()
                        .filter { p.confidences[$0.offset] > 0.35 }
                        .map { $0.element.y }
                    if let lo = ys.min(), let hi = ys.max(), hi - lo > 0.15 {
                        spans.append((hi - lo) * Float(videoSize.height))
                    }
                }
                if !spans.isEmpty {
                    let med = spans.sorted()[spans.count / 2]
                    anchorZ = cam.fy * 1.62 / med          // 可见跨度≈身高的0.94
                }
            }
            // FIT with plain sensor gravity (tilting gravity inside the
            // bounded grid collapses it to a slow solution — verified
            // regression 60→36 m/s). The ground-plane pitch goes only into
            // the FLIGHT camera used for integration/projection (offline
            // lesson: pitch-as-zero throws the landing point). Tee at depth
            // anchorZ + eye-height camera (~1.7 m) give the horizon row:
            // y_h = y_tee − fy·1.7/Z; pitch = atan((cy−y_h)/fy).
            var camFlight = cam
            // Ground-plane pitch → the FLIGHT camera's gravity, so the descent
            // recedes to the horizon instead of falling to the foreground.
            // PRIMARY: detect the horizon row directly (robust). FALLBACK: the
            // tee+eye-height geometric estimate (fragile — a slightly-low tee
            // flips it negative, throwing the landing to the foreground).
            if !hasMeasuredGravity {
                var pitch: Float? = geoPitch          // GeoCalib (best) if it ran
                if let p = geoPitch {
                    print("[VideoAnalyzer] 📐 pitch from GeoCalib: \(p * 180 / .pi)°")
                } else if let yH = await detectHorizonY(url: url, atSeconds: impactSec, orientation: cgOrientation) {
                    pitch = atan((cam.cy - yH) / cam.fy)
                    print("[VideoAnalyzer] 📐 pitch from horizon y=\(Int(yH)): \(pitch! * 180 / .pi)°")
                } else if let tee = teePixel ?? obs.first.map({ (u: $0.u, v: $0.v) }) {
                    let yH = tee.v - cam.fy * 1.7 / anchorZ
                    pitch = atan((cam.cy - yH) / cam.fy)
                    print("[VideoAnalyzer] 📐 pitch (tee est., no horizon): \(pitch! * 180 / .pi)°")
                }
                if let p = pitch {
                    camFlight.gravityDir = SIMD3<Float>(0, cos(p), sin(p))
                }
            }
            // Launch witness (motion pass near-tee mover at impact): pins the
            // fit's launch TIME, its most degenerate dimension, and gives a
            // better launch pixel than the address clubhead. With absolute
            // time bases aligned, pre-impact statics are cut EXACTLY: any
            // observation at/before the witness is the address ball (verified:
            // YOLO glued a static obs 2 frames BEFORE impact onto the chain,
            // which flipped t0Hint positive and wrecked the fit at 92 px).
            var t0Hint: Float? = nil
            if let w = launchWitness, let fm = traj.firstObsMediaTime {
                let absTimes = obs.map { fm + Double($0.t) }
                if let keepFrom = absTimes.firstIndex(where: { $0 > w.t + 0.005 }),
                   obs.count - keepFrom >= 5 {
                    if keepFrom > 0 {
                        print("[VideoAnalyzer] 🧹 cut \(keepFrom) pre-impact obs (≤ witness t)")
                    }
                    let newFm = absTimes[keepFrom]
                    obs = obs.suffix(from: keepFrom).map {
                        .init(u: $0.u, v: $0.v, t: Float(fm + Double($0.t) - newFm))
                    }
                    obsAbsZero = newFm
                    t0Hint = Float(w.t - newFm)
                    teePixel = (w.x * Float(videoSize.width), w.y * Float(videoSize.height))
                    print("[VideoAnalyzer] 🎯 t0 pinned by witness: \(t0Hint!)s")
                }
            }
            // Plateau trim: a DTL ball flying into the screen (receding) has its
            // image motion decay to ~0 near the end — those tail points carry no
            // 3D info and DOMINATE/bias the fit (verified offline V2: 47→24 px).
            // Keep the high-motion prefix. No-op on clean rising night shots.
            let obsBeforeTrim = obs.count
            if obs.count >= 5 {
                var steps: [Float] = []
                for i in 1..<obs.count { steps.append(hypot(obs[i].u - obs[i - 1].u, obs[i].v - obs[i - 1].v)) }
                let med = steps.sorted()[steps.count / 2]
                let thr = max(Float(videoSize.height) * 0.008, 0.35 * med)
                var cut = obs.count, low = 0
                for (k, s) in steps.enumerated() {
                    low = s < thr ? low + 1 : 0
                    if low >= 2 { cut = k; break }
                }
                // Keep ≥ 4 points, matching the offline `4 <= cut < len(track)`.
                // This used to demand ≥ 8 because over-trimming produced flat or
                // negative launches — but that was the coordinate/impact-gate bugs
                // upstream feeding the solver garbage, not the trim being greedy.
                if cut >= 4, cut < obs.count {
                    obs = Array(obs.prefix(cut))
                    print("[VideoAnalyzer] 🪚 plateau trim (receding tail) → \(obs.count) obs")
                }
            }
            // Trimming away more than a couple of points means the ball spent the
            // window receding: direction stays reliable, absolute scale doesn't.
            let receding = obs.count < obsBeforeTrim - 2
            let st = BallFlightSolver.solveBoundedState(obs, camera: cam, anchorZ: anchorZ,
                                                        teePixel: teePixel, t0Hint: t0Hint)
            ballFlight = st.map { BallFlightSolver.metrics(from: $0, camera: camFlight) }
            // Degenerate-fit reject: a wrong tracer (flat/descending or pinned at
            // the speed ceiling) is worse than none. launch < 2° in the FLIGHT
            // frame = pitch tilt flipped a valid rise negative (device −3° bug);
            // speed ≥ 74 = grid-boundary blow-up. Suppress rather than mislead.
            // Off-frame tee = the chain isn't a ball launched from the mat. On V2
            // TrackNet locked the CLUB HEAD's follow-through (sweeps up-left); its
            // back-extrapolation lands OFF-FRAME (teeX 1.25). A ball can't launch
            // off-screen → the chain is the club, not the ball → reject.
            let teeOffFrame = teePixel.map {
                $0.u < -0.1 * Float(videoSize.width) || $0.u > 1.1 * Float(videoSize.width) ||
                $0.v < -0.1 * Float(videoSize.height) || $0.v > 1.1 * Float(videoSize.height)
            } ?? false
            if let bf = ballFlight,
               bf.launchAngleDeg < 2 || bf.launchAngleDeg > 44 || bf.speedMps >= 74 || teeOffFrame {
                print("[VideoAnalyzer] ⚠️ ballFlight rejected: \(bf.speedMps) m/s, \(bf.launchAngleDeg)° teeOffFrame=\(teeOffFrame) — likely club not ball")
                ballFlight = nil
            }
            // Confidence, mirroring the offline pipeline. Inside the hard reject
            // above sits a softer plausibility window: a fit can be physically
            // possible yet still be too poor a measurement to put a number on.
            if let bf = ballFlight {
                let plausible = (20...80).contains(bf.speedMps)
                    && (6...35).contains(bf.launchAngleDeg)
                    && (10...320).contains(bf.carryMeters)
                // Reprojection error is in PIXELS, so the bar has to scale with
                // the frame. The offline pipeline's flat `err > 14` is measured
                // on 720-tall clips; reused as-is against a 1080×1920 capture it
                // is 2.7× stricter and fails fits that are perfectly good, which
                // is why every device swing came back "距离未标定".
                let errBar = 14.0 / 720.0 * Float(videoSize.height)
                let conf: BallFlight.Confidence
                if bf.reprojErrPx > errBar || obs.count < 5 || !plausible { conf = .low }
                else if receding { conf = .mid }
                else { conf = .high }
                print("[VideoAnalyzer] 🎯 conf=\(conf.rawValue) err=\(String(format: "%.1f", bf.reprojErrPx))/\(String(format: "%.0f", errBar)) obs=\(obs.count) plausible=\(plausible) receding=\(receding)")
                ballFlight = BallFlight(speedMps: bf.speedMps,
                                        launchAngleDeg: bf.launchAngleDeg,
                                        carryMeters: bf.carryMeters,
                                        reprojErrPx: bf.reprojErrPx,
                                        confidence: conf)
            }
            // Field/debug dump: the whole ball-pipeline decision trail to a
            // JSON in Documents — sim log capture is unreliable and device
            // diagnosis needs it anyway (AirDrop-able).
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                var dump: [String: Any] = [
                    "obsCount": obs.count,
                    "obsTimes": obs.map { Double($0.t) },
                    "anchorZ": Double(anchorZ),
                    "teePixel": teePixel.map { [Double($0.u), Double($0.v)] } ?? [],
                    "gravityFlight": [Double(camFlight.gravityDir.x),
                                      Double(camFlight.gravityDir.y),
                                      Double(camFlight.gravityDir.z)],
                    "trajSource": ballTraj?.confidence ?? -1,
                    "merge": ballMergeDebug,
                ]
                if let st {
                    dump["fit"] = ["speed": Double(simd_length(st.v)),
                                   "errPx": Double(st.err), "t0": Double(st.t0)]
                }
                dump["t0Hint"] = t0Hint.map(Double.init) ?? -999
                dump["witness"] = launchWitness.map { [Double($0.x), Double($0.y), $0.t] } ?? []
                if let bf = ballFlight {
                    dump["flight"] = ["speed": Double(bf.speedMps),
                                      "launch": Double(bf.launchAngleDeg),
                                      "carry": Double(bf.carryMeters)]
                }
                if let d = try? JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys]) {
                    try? d.write(to: docs.appendingPathComponent("ball_debug_latest.json"), options: .atomic)
                }
            }
            if let bf = ballFlight, let st {
                print("[VideoAnalyzer] ✅ ball flight: \(bf.speedMps) m/s, launch \(bf.launchAngleDeg)°, carry \(bf.carryMeters) m (anchorZ \(anchorZ), t0 \(st.t0))")
                let path = BallFlightSolver.projectedFlight(from: st, camera: camFlight)
                if path.count > 2 {
                    // Zero the arc on the fit's LAUNCH (t0), not impactSec: the
                    // ball sits on the tee until impact, then launches, so the
                    // tee must map to render-time 0 (= the impact frame the
                    // overlay reveals from, playerTime − impactClipT). Anchoring
                    // on impactSec pushed the tee to a small NEGATIVE offset
                    // (launch 2.055 < impact 2.13) where the ≥0 filter cut it,
                    // so the tracer floated in mid-air instead of starting at the
                    // mat ball. Launch-relative puts the mat ball exactly at t=0.
                    _ = obsAbsZero; _ = impactSec
                    let pred = path.map {
                        BallTrajectory.Point(x: $0.u / Float(videoSize.width),
                                             y: $0.v / Float(videoSize.height),
                                             timeOffsetSeconds: Double($0.t - st.t0))
                    }
                    ballTraj?.predictedPoints = pred
                    print("[VideoAnalyzer] ✅ predicted arc: \(pred.count) pts, "
                          + "t \(String(format: "%.2f", pred.first?.timeOffsetSeconds ?? 0))…"
                          + "\(String(format: "%.2f", pred.last?.timeOffsetSeconds ?? 0)) "
                          + "(obsAbsZero \(String(format: "%.2f", obsAbsZero)), impactSec \(String(format: "%.2f", impactSec)))")
                }
            }
        }

        perf("geocalib + ball flight fit")
        let report = SwingReport(
            recordingURL: url,
            poseFrames: poses,
            events: events,
            metrics: metrics,
            perEvent: perEvent,
            dynamics: dynamics,
            ballTrajectory: ballTraj,
            ballFlight: ballFlight,
            clubTrack: clubTrack,
            videoSize: videoSize,
            viewpoint: viewpoint
        )
        await MainActor.run {
            self.report = report
            self.status = .done
        }
    }

    /// Horizon pixel row = the strongest bright band (range lights / field-sky
    /// edge) in the upper 15–55 % of the frame at `atSeconds`. Robust
    /// ground-plane pitch, unlike the tee+eye-height estimate. Upright
    /// (orientation .up) only — native == display there; nil else (caller
    /// falls back).
    private func detectHorizonY(url: URL, atSeconds: Double,
                                orientation: CGImagePropertyOrientation) async -> Float? {
        guard orientation == .up else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, atSeconds), preferredTimescale: 600),
                                       duration: CMTime(seconds: 0.2, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading(),
              let sample = output.copyNextSampleBuffer(),
              let pb = CMSampleBufferGetImageBuffer(sample) else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        var bestRow = -1, bestCount = 0
        for y in (h * 15 / 100)..<(h * 55 / 100) {
            var cnt = 0, x = 0
            let row = y * bpr
            while x < w { if luma[row + x] > 175 { cnt += 1 }; x += 4 }
            if cnt > bestCount { bestCount = cnt; bestRow = y }
        }
        reader.cancelReading()
        guard bestRow >= 0, bestCount > 3 else { return nil }
        return Float(bestRow)
    }

    private func fail(_ msg: String) async {
        await MainActor.run { self.status = .failed(msg) }
    }

    /// Decode a video track's `preferredTransform` into a CGImagePropertyOrientation
    /// so Vision/CoreML knows how to rotate the raw sample buffers. Standard iPhone
    /// portrait recording → .right; landscape → .up; etc.
    private static func cgImageOrientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        let eps: CGFloat = 0.01
        func eq(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) < eps }
        if eq(t.a, 0)  && eq(t.b, 1)  && eq(t.c, -1) && eq(t.d, 0)  { return .right }     // portrait
        if eq(t.a, 0)  && eq(t.b, -1) && eq(t.c, 1)  && eq(t.d, 0)  { return .left }
        if eq(t.a, 1)  && eq(t.b, 0)  && eq(t.c, 0)  && eq(t.d, 1)  { return .up }        // landscape
        if eq(t.a, -1) && eq(t.b, 0)  && eq(t.c, 0)  && eq(t.d, -1) { return .down }
        // Mirrored variants (front-camera recording etc.)
        if eq(t.a, -1) && eq(t.b, 0)  && eq(t.c, 0)  && eq(t.d, 1)  { return .upMirrored }
        if eq(t.a, 1)  && eq(t.b, 0)  && eq(t.c, 0)  && eq(t.d, -1) { return .downMirrored }
        if eq(t.a, 0)  && eq(t.b, -1) && eq(t.c, -1) && eq(t.d, 0)  { return .leftMirrored }
        if eq(t.a, 0)  && eq(t.b, 1)  && eq(t.c, 1)  && eq(t.d, 0)  { return .rightMirrored }
        return .up
    }
}
