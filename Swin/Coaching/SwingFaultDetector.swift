import Foundation

// NOTE: FaultThresholds + FaultRanker live in this file (not separate files)
// because this project's .xcodeproj references sources file-by-file rather than
// via a synchronized group — keeping them here avoids a manual pbxproj edit.
// They're conceptually "part of fault detection" anyway: the calibratable
// thresholds and the root-cause ranker.

/// Centralized, tunable thresholds for every fault. Each fault has a `trigger`
/// (severity 0, where it starts counting) and a `severe` (severity 1, where it
/// saturates). The two can be in either order — for "smaller is worse" faults
/// `severe < trigger`, and `(value-trigger)/(severe-trigger)` handles both.
///
/// ⚑ EVERY value is an engineering first-pass guess so the pipeline runs
/// end-to-end today. They are meant to be CALIBRATED against the expert's
/// annotated clip set (轻/中/重 labels), not trusted as-is. Calibration =
/// editing this struct, no detector logic changes.
struct FaultThresholds: Sendable {
    var earlyExtSpineTrigger = 8.0;     var earlyExtSpineSevere = 20.0
    var earlyExtHipRiseSupport = 0.05
    var ottTrigger = 0.08;              var ottSevere = 0.25
    var swayTrigger = 0.12;             var swaySevere = 0.35
    var reversePivotTrigger = 0.10;     var reversePivotSevere = 0.30
    // Rotation thresholds are deliberately LOOSE: a 2D camera foreshortens
    // shoulder/hip rotation, so our measured X-factor / hip-turn reads well
    // below the true 3D angle (our 2-view fusion tops out ~30° X-factor vs a
    // tour pro's ~65°). A tight trigger therefore flags good — even pro —
    // swings as "under-rotated". Fire only when the 2D value is genuinely low.
    var xFactorTrigger = 18.0;          var xFactorSevere = 5.0
    var hipTurnTrigger = 20.0;          var hipTurnSevere = 8.0
    var shortBackswingTrigger = 0.10;   var shortBackswingSevere = -0.30
    var flyingElbowTrigger = 0.05;      var flyingElbowSevere = 0.30
    var lossPostureTrigger = 10.0;      var lossPostureSevere = 25.0
    var headMoveTrigger = 0.42;         var headMoveSevere = 0.75
    var chickenWingTrigger = 140.0;     var chickenWingSevere = 100.0
    var slideTrigger = 0.25;            var slideSevere = 0.60
    var braceTrigger = 5.0;             var braceSevere = -10.0
    var fastTempoTrigger = 2.0;         var fastTempoSevere = 1.0
    var slowTempoTrigger = 4.5;         var slowTempoSevere = 6.5
    var excessSpineTrigger = 55.0;      var excessSpineSevere = 75.0
    var finishWobbleTrigger = 0.04;     var finishWobbleSevere = 0.12
    /// Faults below this confidence are flagged "tentative" (still shown, but
    /// the user/LLM know they're uncertain) — NOT dropped. "发现的问题都得有".
    /// Calibrate alongside the triggers.
    var tentativeConfidence = 0.60

    /// Hard severity floor: a fault barely past its trigger (e.g. spine stood
    /// up 8.2° when trigger is 8°, severity 0.02) is a borderline non-event and
    /// must not surface — not even with corroborating evidence pushing its
    /// confidence over the line. Without this floor a near-zero "root cause"
    /// can wrongly suppress a real symptom downstream.
    var minSeverityToReport = 0.10

    /// A root cause only suppresses its downstream symptoms if the root itself
    /// is meaningfully present (severity ≥ this). Stops a barely-there root
    /// (sev 0.02) from demoting a clear symptom (sev 1.0).
    var rootSuppressionMinSeverity = 0.30

    static let `default` = FaultThresholds()
}

/// Organizes the raw fault list for both the user and the LLM coach: it KEEPS
/// every detected fault (nothing is dropped — "发现的问题都得有"), annotates
/// each symptom with the causal chain (`causedBy`), and sorts root-cause-first.
///
///   1. causal annotation: a symptom gets `causedBy = [present significant
///      roots]`. A lone chicken-wing (no early extension present) stays a root
///      in its own right with `causedBy = nil`.
///   2. combined score = severity × confidence × layer-weight, with caused
///      symptoms demoted (×suppressionFactor) so they sort UNDER their root —
///      but they remain in the list, tagged with the relationship.
///   3. confidence is NOT used to drop anything anymore; low-confidence faults
///      are kept and flagged "tentative" downstream so the user/LLM see them
///      but know they're uncertain. The only filter is the severity floor
///      applied earlier in `fault()`.
///
/// `.first` is still the root cause (used as `primaryFault`). Cross-swing
/// hysteresis lives in SessionCoach (focus lock/release), not here.
struct FaultRanker {
    /// symptom → its possible UPSTREAM root causes. If any listed root is
    /// present AND significant, the symptom is tagged `causedBy` it and demoted
    /// in ranking (so the root shows above it). Multi-level chains are fine
    /// (e.g. hip-turn → over-the-top → chicken-wing renders as two links).
    /// ⚑ Engineering first-pass from common golf biomechanics — the exact
    /// causal graph is for the expert to confirm/extend.
    private let suppression: [SwingFaultID: [SwingFaultID]] = [
        .chickenWing:         [.earlyExtension, .overTheTop, .flyingElbow],
        .noBrace:             [.earlyExtension, .reversePivot],
        .slide:               [.earlyExtension, .overTheTop, .sway],
        .poorFinish:          [.earlyExtension, .overTheTop, .reversePivot, .sway, .noBrace],
        .lossOfPosture:       [.earlyExtension, .excessiveSpineTilt, .headMovement],
        .insufficientXFactor: [.insufficientHipTurn, .shortBackswing],
        .overTheTop:          [.insufficientHipTurn, .flyingElbow],
        .earlyExtension:      [.reversePivot, .excessiveSpineTilt],
        .headMovement:        [.sway],   // head drift nests UNDER sway (see screenshot)
    ]
    private let suppressionFactor = 0.3

    func organize(_ faults: [SwingFault],
                  rootSuppressionMinSeverity: Double = 0.30) -> [SwingFault] {
        func rootPresent(_ rootId: SwingFaultID) -> Bool {
            faults.contains { $0.id == rootId && $0.severity >= rootSuppressionMinSeverity }
        }
        // Annotate causal chain — keep every fault.
        let annotated: [SwingFault] = faults.map { f in
            guard let roots = suppression[f.id] else { return f }
            let active = roots.filter(rootPresent)
            guard !active.isEmpty else { return f }
            var g = f
            g.causedBy = active
            return g
        }
        // Strict root-first ordering: the PRIMARY key is the causal layer
        // (root > mid > symptom) so a root cause ALWAYS sits above the mid /
        // symptom faults it produces — regardless of their severity. The
        // secondary key (severity × confidence, caused-symptoms demoted) only
        // breaks ties WITHIN a layer. This is the "最上面是最root" rule.
        func rank(_ f: SwingFault) -> (Double, Double) {
            let base = f.severity * (f.confidence ?? 0.6)
            let demote = f.causedBy != nil ? suppressionFactor : 1.0
            return (f.id.layer.weight, base * demote)
        }
        return annotated.sorted {
            let a = rank($0), b = rank($1)
            return a.0 != b.0 ? a.0 > b.0 : a.1 > b.1
        }
    }
}

/// Runs each fault detector against a finished `SwingReport` and returns the
/// fault list, ranked root-cause-first. Pure code — no LLM, no network, no
/// learned model. Stable input → stable output, so this is the foundation for
/// scoring + coaching state.
///
/// v0.2 rewrite:
///   - reads the richer `SwingDynamics` (trajectory/interval metrics) plus
///     `metrics` / `perEvent`, so faults are COMBINATION-judged (main signal +
///     corroborating evidence) instead of single-metric
///   - every fault carries `severity` + `confidence` + `margin`
///   - thresholds live in one calibratable `FaultThresholds` struct
///   - the final list is ranked by `FaultRanker` (combined score + root/symptom
///     suppression + confidence gate), so `.first` is the most-actionable root
///
/// The `detect(report:)` signature is unchanged, so SwingScorer / SessionCoach
/// / the annotator are untouched — they automatically get the better ordering.
struct SwingFaultDetector {
    var thresholds: FaultThresholds = .default

    func detect(report: SwingReport) -> [SwingFault] {
        let d = report.dynamics
        let m = report.metrics
        let candidates: [SwingFault?] = [
            detectEarlyExtension(report, d),
            detectOverTheTop(d),
            detectSway(d),
            detectReversePivot(d),
            detectInsufficientXFactor(report, m),
            detectInsufficientHipTurn(m),
            detectShortBackswing(d),
            detectFlyingElbow(d),
            detectLossOfPosture(d),
            detectHeadMovement(d),
            detectChickenWing(report),
            detectSlide(d),
            detectNoBrace(d),
            detectTempo(m),
            detectExcessiveSpineTilt(report),
            detectPoorFinish(d),
        ]
        // Viewpoint hard-filter: drop faults that are geometrically INVISIBLE
        // from this camera angle (turn from down-the-line, swing path from
        // face-on). Any value would be a projection artifact, so it's removed
        // entirely — not reported, not ranked, not even shown as "tentative".
        let raw = candidates.compactMap { $0 }
            .filter { $0.id.hiddenViewpoint != report.viewpoint }
        return FaultRanker().organize(
            raw,
            rootSuppressionMinSeverity: thresholds.rootSuppressionMinSeverity
        )
    }

    // MARK: - individual detectors (combination-judged)

    /// Early extension = spine stands up at impact (lost forward tilt),
    /// corroborated by the hips rising. Main signal alone = weaker call;
    /// main + hip-rise support = high confidence.
    private func detectEarlyExtension(_ r: SwingReport, _ d: SwingDynamics?) -> SwingFault? {
        guard let addr = perEvent(r, .address)?.spineTilt,
              let imp = perEvent(r, .impact)?.spineTilt else { return nil }
        let lost = addr - imp
        let s = sev(lost, thresholds.earlyExtSpineTrigger, thresholds.earlyExtSpineSevere)
        let support = (d?.hipRise ?? 0) > thresholds.earlyExtHipRiseSupport
        return fault(.earlyExtension, s, .impact, lost, "° spine stood up", support)
    }

    /// Over the top = hands bow OUTSIDE the top→impact line in early downswing.
    private func detectOverTheTop(_ d: SwingDynamics?) -> SwingFault? {
        guard let v = d?.handOutThenIn else { return nil }
        let s = sev(v, thresholds.ottTrigger, thresholds.ottSevere)
        return fault(.overTheTop, s, .midDownswing, v * 100, "% hand path outside", false)
    }

    /// Sway = head / upper body drifts AWAY from target at the top. (Judged from
    /// the nose toward-target signal — this is the version that correctly flags
    /// sway as the root cause on real PoseTCN-detected events. A short-lived
    /// "use the hips instead" rewrite broke it on swings where the sway shows in
    /// the upper body more than the hips, so it's reverted.)
    private func detectSway(_ d: SwingDynamics?) -> SwingFault? {
        guard let head = d?.headTowardTargetAtTop else { return nil }
        let away = -head                       // away-from-target is the fault
        let s = sev(away, thresholds.swayTrigger, thresholds.swaySevere)
        return fault(.sway, s, .top, away * 100, "% away from target", false)
    }

    /// Reverse pivot = head drifts TOWARD target at the top (weight hangs on lead side).
    private func detectReversePivot(_ d: SwingDynamics?) -> SwingFault? {
        guard let head = d?.headTowardTargetAtTop else { return nil }
        let s = sev(head, thresholds.reversePivotTrigger, thresholds.reversePivotSevere)
        return fault(.reversePivot, s, .top, head * 100, "% toward target", false)
    }

    /// Insufficient X-factor = shoulders barely out-turn hips at top (smaller worse).
    private func detectInsufficientXFactor(_ r: SwingReport, _ m: SwingMetrics?) -> SwingFault? {
        let xf = perEvent(r, .top)?.xFactor ?? m?.xFactor
        guard let xf else { return nil }
        let a = abs(xf)
        guard a > 1 else { return nil }        // ~0 usually means missing data
        let s = sev(a, thresholds.xFactorTrigger, thresholds.xFactorSevere)
        return fault(.insufficientXFactor, s, .top, a, "° X-factor", false)
    }

    /// Insufficient hip turn = hips under-rotate at top (smaller worse).
    private func detectInsufficientHipTurn(_ m: SwingMetrics?) -> SwingFault? {
        guard let m else { return nil }
        let a = abs(m.hipTurn)
        guard a > 1 else { return nil }
        let s = sev(a, thresholds.hipTurnTrigger, thresholds.hipTurnSevere)
        return fault(.insufficientHipTurn, s, .top, a, "° hip turn", false)
    }

    /// Short backswing = lead wrist never gets above the shoulder at top.
    private func detectShortBackswing(_ d: SwingDynamics?) -> SwingFault? {
        guard let v = d?.leadWristAboveShoulderAtTop else { return nil }
        let s = sev(v, thresholds.shortBackswingTrigger, thresholds.shortBackswingSevere)
        return fault(.shortBackswing, s, .top, v * 100, "% wrist vs shoulder", false)
    }

    /// Flying elbow = trail elbow lifts above shoulder line at top.
    private func detectFlyingElbow(_ d: SwingDynamics?) -> SwingFault? {
        guard let v = d?.trailElbowAboveShoulderAtTop else { return nil }
        let s = sev(v, thresholds.flyingElbowTrigger, thresholds.flyingElbowSevere)
        return fault(.flyingElbow, s, .top, v * 100, "% elbow above shoulder", false)
    }

    /// Loss of posture = spine tilt varies a lot across addr/top/impact.
    private func detectLossOfPosture(_ d: SwingDynamics?) -> SwingFault? {
        guard let v = d?.spineVariance else { return nil }
        let s = sev(v, thresholds.lossPostureTrigger, thresholds.lossPostureSevere)
        return fault(.lossOfPosture, s, .impact, v, "° spine variance", false)
    }

    /// Head movement = head drifts too far over the addr→impact window.
    private func detectHeadMovement(_ d: SwingDynamics?) -> SwingFault? {
        guard let v = d?.headMaxOffset else { return nil }
        let s = sev(v, thresholds.headMoveTrigger, thresholds.headMoveSevere)
        return fault(.headMovement, s, .impact, v * 100, "% head drift", false)
    }

    /// Chicken wing = lead elbow still bent on the follow-through.
    private func detectChickenWing(_ r: SwingReport) -> SwingFault? {
        guard let v = perEvent(r, .midFollowThrough)?.leadElbow else { return nil }
        let s = sev(v, thresholds.chickenWingTrigger, thresholds.chickenWingSevere)
        return fault(.chickenWing, s, .midFollowThrough, v, "° lead elbow", false)
    }

    /// Slide = hips drift too far toward the target at impact (vs a healthy bump).
    private func detectSlide(_ d: SwingDynamics?) -> SwingFault? {
        guard let v = d?.hipDriftTowardTargetAtImpact else { return nil }
        let s = sev(v, thresholds.slideTrigger, thresholds.slideSevere)
        return fault(.slide, s, .impact, v * 100, "% hip toward target", false)
    }

    /// No brace = lead leg fails to post up (straighten) into impact,
    /// corroborated by the hips not getting over the front foot.
    private func detectNoBrace(_ d: SwingDynamics?) -> SwingFault? {
        guard let v = d?.braceExtension else { return nil }
        let s = sev(v, thresholds.braceTrigger, thresholds.braceSevere)
        let support = (d?.hipOverFrontFoot ?? 1) < 0
        return fault(.noBrace, s, .impact, v, "° lead knee extension", support)
    }

    /// Tempo = backswing/downswing frame ratio, ideal ~3:1.
    private func detectTempo(_ m: SwingMetrics?) -> SwingFault? {
        guard let t = m?.tempoRatio, t > 0 else { return nil }
        if t < thresholds.fastTempoTrigger {
            let s = sev(t, thresholds.fastTempoTrigger, thresholds.fastTempoSevere)
            return fault(.fastTempo, s, .top, t, ":1 tempo", false)
        }
        if t > thresholds.slowTempoTrigger {
            let s = sev(t, thresholds.slowTempoTrigger, thresholds.slowTempoSevere)
            return fault(.slowTempo, s, .top, t, ":1 tempo", false)
        }
        return nil
    }

    /// Excessive spine tilt = over-hinged at address.
    private func detectExcessiveSpineTilt(_ r: SwingReport) -> SwingFault? {
        guard let v = perEvent(r, .address)?.spineTilt else { return nil }
        let s = sev(v, thresholds.excessSpineTrigger, thresholds.excessSpineSevere)
        return fault(.excessiveSpineTilt, s, .address, v, "° spine tilt", false)
    }

    /// Poor finish = body still wobbling over the last frames (not balanced).
    private func detectPoorFinish(_ d: SwingDynamics?) -> SwingFault? {
        guard let v = d?.finishWobble else { return nil }
        let s = sev(v, thresholds.finishWobbleTrigger, thresholds.finishWobbleSevere)
        return fault(.poorFinish, s, .finish, v * 100, "% finish wobble", false)
    }

    // MARK: - helpers

    /// Severity 0→1 from a value relative to (trigger, severe). Works in both
    /// directions: when `severe < trigger` ("smaller is worse") the formula
    /// still maps trigger→0 and severe→1. Clamped, so values on the safe side
    /// of trigger return 0 (= not a fault).
    private func sev(_ value: Double, _ trigger: Double, _ severe: Double) -> Double {
        guard severe != trigger else { return value >= trigger ? 1 : 0 }
        return max(0, min(1, (value - trigger) / (severe - trigger)))
    }

    /// Confidence from severity margin + whether corroborating evidence fired.
    /// At threshold (margin 0) a lone signal sits at 0.5; supporting evidence
    /// or a big margin pushes it up. The ranker drops anything below
    /// `minConfidenceToReport`.
    private func confidence(_ s: Double, support: Bool) -> Double {
        min(1, (0.5 + 0.5 * s) * (support ? 1.25 : 1.0))
    }

    private func fault(_ id: SwingFaultID, _ severity: Double, _ event: SwingEvent?,
                       _ value: Double, _ unit: String, _ support: Bool) -> SwingFault? {
        // Severity floor: borderline-trigger faults are non-events, even if
        // supporting evidence would otherwise lift their confidence past the gate.
        guard severity > thresholds.minSeverityToReport else { return nil }
        return SwingFault(
            id: id,
            severity: severity,
            anchorEvent: event,
            evidenceValue: value,
            evidenceUnit: unit,
            confidence: confidence(severity, support: support),
            margin: severity
        )
    }

    private func perEvent(_ report: SwingReport, _ event: SwingEvent) -> PerEventMetrics? {
        report.perEvent.first(where: { $0.event == event.displayName })
    }
}

// MARK: - Fault evidence (the "why" — for click-to-show-on-video)

/// The geometry a fault was judged from, resolved to concrete COCO joint
/// indices (handedness applied) so the presentation layer can overlay it on
/// the video frame: highlight the joints, draw the lines, mark the angle, and
/// print the measured value. This is the rule engine's explainability made
/// visual — "we flagged this because THIS angle/line did THIS".
///
/// The presentation layer owns the actual drawing (it has the PoseOverlay
/// anisotropic coordinate transform); this just says WHAT to draw and the
/// readout text. `lines` are joint-index polylines; a 3-joint polyline whose
/// middle index == `angleVertex` should also get an angle arc.
struct FaultEvidence: Sendable {
    var frame: Int                 // which pose/video frame to show (anchor)
    var highlightJoints: [Int]     // COCO indices to ring/emphasize
    var lines: [[Int]]             // polylines (joint-index sequences) to draw
    var angleVertex: Int?          // joint to draw an angle arc at, if any
    var readout: String            // the basis, in words (may include the value)
    // --- coach-style reference guides, drawn from the ADDRESS frame ---
    /// Same lines drawn from the ADDRESS pose as a DASHED baseline — compare
    /// "now" (solid) vs "start" (dashed) to see the change (spine standing up,
    /// hips sliding…).
    var referenceLines: [[Int]] = []
    /// Vertical guide line through each joint's ADDRESS x position — the fixed
    /// reference axis a coach draws (e.g. trail-hip line to reveal sway).
    var verticals: [Int] = []
    /// Horizontal guide line through each joint's ADDRESS y position — coach's
    /// level reference (shoulder/hip line for turn, head-height for lifting).
    var horizontals: [Int] = []
    /// Draw the classic head circle around the ADDRESS head — the standard
    /// guide for spotting lateral head movement through the swing.
    var headCircle: Bool = false
    /// Joints to draw a delta arrow for: from their ADDRESS position to their
    /// CURRENT position — shows how far and which way the joint moved, instead
    /// of relying on the text readout alone.
    var deltaJoints: [Int] = []
    /// Draw this joint's MOTION PATH across the downswing (top → impact) as a
    /// traced line — for PATH faults (over-the-top), where a single static line
    /// can't show the problem; the bowed-out hand path can.
    var pathJoint: Int? = nil
    /// For ROTATION faults (shoulder/hip turn) that 2D side-on video can't show
    /// directly: a top-down gauge of how much they turned vs a healthy target.
    /// Abstract, off-frame — doesn't fight the projection.
    var turnGauge: TurnGauge? = nil
    /// Draw an IDEAL downswing arc (top→impact, bowed toward the body) as a
    /// dashed reference, so the user's actual `pathJoint` trace can be compared
    /// against it. Over-the-top = actual path bows OUTSIDE this ideal arc.
    /// Geometric approximation (not a personalized optimum — that needs P3).
    var idealArc: Bool = false
}

/// Top-down rotation gauge data: how far the body turned vs a healthy
/// reference. The angle is 2D-approximate (rotation isn't reliable from one
/// side-on view), so it's illustrative — paired with the "minor/noticeable"
/// severity, not presented as a precise measurement.
struct TurnGauge: Sendable {
    enum Mode: Sendable { case coil, hip }   // emphasize shoulder-vs-hip gap, or hip turn
    var shoulderTurn: Double   // measured shoulder turn, degrees (approximate)
    var hipTurn: Double        // measured hip turn, degrees (approximate)
    var mode: Mode
}

/// Builds the evidence geometry for a fault on demand (at click time). Lives
/// next to the detector because it mirrors the SAME joints/lines the detector
/// judged from — keep the two in sync when thresholds/metrics change.
enum FaultEvidenceBuilder {
    static func evidence(for fault: SwingFault, report: SwingReport) -> FaultEvidence? {
        let isRight = report.events.handedness == .right
        let leadShoulder  = isRight ? Joint.leftShoulder  : Joint.rightShoulder
        let leadElbow     = isRight ? Joint.leftElbow     : Joint.rightElbow
        let leadWrist     = isRight ? Joint.leftWrist     : Joint.rightWrist
        let leadHip       = isRight ? Joint.leftHip       : Joint.rightHip
        let leadKnee      = isRight ? Joint.leftKnee      : Joint.rightKnee
        let leadAnkle     = isRight ? Joint.leftAnkle     : Joint.rightAnkle
        let trailShoulder = isRight ? Joint.rightShoulder : Joint.leftShoulder
        let trailElbow    = isRight ? Joint.rightElbow    : Joint.leftElbow

        let frame = fault.anchorEvent.flatMap { report.events.frame(for: $0) } ?? -1
        guard frame >= 0 else { return nil }

        // spine line (hip-mid → shoulder-mid) approximated by the lead-side
        // hip→shoulder segment, which the overlay can also render as a true
        // mid-line if it prefers.
        let spine = [[leadHip, leadShoulder]]
        let shoulders = [Joint.leftShoulder, Joint.rightShoulder]
        let hips = [Joint.leftHip, Joint.rightHip]

        func val(_ fallback: String) -> String {
            guard let v = fault.evidenceValue, let u = fault.evidenceUnit else { return fallback }
            return String(format: "%.0f%@", v, u.hasPrefix("°") ? "°" : " \(u)")
        }

        switch fault.id {
        case .earlyExtension, .lossOfPosture:
            return FaultEvidence(frame: frame, highlightJoints: shoulders + hips,
                                 lines: spine, angleVertex: nil,
                                 readout: String(localized: "脊柱角度：现在（实线）对比站位时（虚线）— ") + val(String(localized: "变了")),
                                 referenceLines: spine, horizontals: [Joint.nose], headCircle: true,
                                 deltaJoints: hips)
        case .excessiveSpineTilt:
            return FaultEvidence(frame: frame, highlightJoints: shoulders + hips,
                                 lines: spine, angleVertex: nil,
                                 readout: String(localized: "站位时脊柱前倾 — ") + val(String(localized: "过多")),
                                 verticals: [leadHip])
        case .flyingElbow:
            return FaultEvidence(frame: frame, highlightJoints: [trailElbow, trailShoulder],
                                 lines: [[trailShoulder, trailElbow]], angleVertex: nil,
                                 readout: String(localized: "后肘抬到了肩线以上"),
                                 horizontals: [trailShoulder])
        case .chickenWing:
            // No address reference line — at address the lead arm hangs down,
            // nowhere near the folded follow-through arm, so it just confuses.
            // The bent angle at the elbow + the arc is the clear signal.
            return FaultEvidence(frame: frame, highlightJoints: [leadShoulder, leadElbow, leadWrist],
                                 lines: [[leadShoulder, leadElbow, leadWrist]], angleVertex: leadElbow,
                                 readout: String(localized: "击球时前臂在肘部弯曲 — ") + val(String(localized: "应更直")))
        case .shortBackswing:
            return FaultEvidence(frame: frame, highlightJoints: [leadWrist, leadShoulder],
                                 lines: [[leadShoulder, leadWrist]], angleVertex: nil,
                                 readout: String(localized: "前手没到达肩线以上"),
                                 horizontals: [leadShoulder])
        case .headMovement:
            return FaultEvidence(frame: frame, highlightJoints: [Joint.nose],
                                 lines: [], angleVertex: nil,
                                 readout: String(localized: "头有没有离开站位时的圆圈？— ") + val(String(localized: "移动了")),
                                 headCircle: true, deltaJoints: [Joint.nose])
        case .reversePivot:
            return FaultEvidence(frame: frame, highlightJoints: [Joint.nose] + shoulders + hips,
                                 lines: spine, angleVertex: nil,
                                 readout: String(localized: "顶点时上半身往目标方向倾"),
                                 referenceLines: spine, verticals: [Joint.nose], deltaJoints: [Joint.nose])
        case .insufficientXFactor:
            return FaultEvidence(frame: frame, highlightJoints: shoulders + hips,
                                 lines: [shoulders, hips], angleVertex: nil,
                                 readout: String(localized: "顶点上身蓄力 — ") + val(String(localized: "不够")),
                                 horizontals: [leadShoulder, leadHip],
                                 turnGauge: TurnGauge(shoulderTurn: abs(report.metrics?.shoulderTurn ?? 0),
                                                      hipTurn: abs(report.metrics?.hipTurn ?? 0),
                                                      mode: .coil))
        case .insufficientHipTurn:
            return FaultEvidence(frame: frame, highlightJoints: hips,
                                 lines: [hips], angleVertex: nil,
                                 readout: String(localized: "相对站位的转髋 — ") + val(String(localized: "不够")),
                                 horizontals: [leadHip],
                                 turnGauge: TurnGauge(shoulderTurn: abs(report.metrics?.shoulderTurn ?? 0),
                                                      hipTurn: abs(report.metrics?.hipTurn ?? 0),
                                                      mode: .hip))
        case .sway:
            // Trail-hip vertical: on the backswing the hips shouldn't slide
            // past this address line away from the target.
            let trailHip = isRight ? Joint.rightHip : Joint.leftHip
            return FaultEvidence(frame: frame, highlightJoints: hips,
                                 lines: [hips], angleVertex: nil,
                                 readout: String(localized: "髋部滑过了后髋线（虚线）— ") + val(String(localized: "偏移")),
                                 verticals: [trailHip], deltaJoints: [trailHip])
        case .slide:
            return FaultEvidence(frame: frame, highlightJoints: hips,
                                 lines: [hips], angleVertex: nil,
                                 readout: String(localized: "髋部滑过了前髋线（虚线）— ") + val(String(localized: "偏移")),
                                 verticals: [leadHip], deltaJoints: [leadHip])
        case .overTheTop:
            // Both lines track the WRIST (we have no club) — actual wrist path
            // vs ideal wrist path, same object. The trace grows with playback
            // (top→current frame) so it stays aligned with where the hand is,
            // instead of a full loop dumped on one frame.
            return FaultEvidence(frame: frame, highlightJoints: [leadWrist],
                                 lines: [], angleVertex: nil,
                                 readout: String(localized: "你的手腕轨迹（实线）对比理想轨迹（虚线）— 抡过头会鼓到外侧"),
                                 pathJoint: leadWrist, idealArc: true)
        case .noBrace:
            return FaultEvidence(frame: frame, highlightJoints: [leadHip, leadKnee, leadAnkle],
                                 lines: [[leadHip, leadKnee, leadAnkle]], angleVertex: leadKnee,
                                 readout: String(localized: "击球时前腿应蹬直支撑 — ") + val(String(localized: "还在弯")),
                                 verticals: [leadAnkle])
        case .poorFinish:
            // Balance check: a vertical through the lead ankle — the body
            // should settle stacked over the front foot at the finish.
            return FaultEvidence(frame: frame, highlightJoints: [Joint.nose, leadAnkle],
                                 lines: [], angleVertex: nil,
                                 readout: String(localized: "收杆时重心稳稳落在前脚上方（竖线）"),
                                 verticals: [leadAnkle])
        case .fastTempo, .slowTempo:
            // Purely timing — no single-frame joint geometry. Just the anchor.
            return FaultEvidence(frame: frame, highlightJoints: [], lines: [], angleVertex: nil,
                                 readout: fault.id.plainLabel)
        }
    }
}
