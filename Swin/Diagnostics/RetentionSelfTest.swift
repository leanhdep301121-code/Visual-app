import Foundation

/// Pure-logic self-test for `RetentionPolicy` (§3.5 dynamic video retention).
///
/// The disk plumbing (export-gating + deletion) is wired into SwingArchive's
/// existing drain paths, but those only fire on a real device (the simulator's
/// virtual camera feeds pose but records no session video). What CAN and should
/// be verified anywhere is the load-bearing DECISION logic: that the keep-sets
/// are bounded and pick the right swings. This runs that against synthetic
/// swings using the real app types.
///
/// Trigger: `RETENTIONTEST=1` (DEBUG only, mirrors the other probes).
enum RetentionSelfTest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["RETENTIONTEST"] == "1" else { return }
        run()
    }

    private static func swing(_ n: Int, total: Int, faults: [SwingFaultID] = [],
                              detection: Double = 0.9) -> AnnotatedSwing {
        let faultObjs: [SwingFault] = faults.enumerated().map { (i, id) -> SwingFault in
            let sev: Double = 0.5 + Double(i) * 0.1
            return SwingFault(id: id, severity: sev, anchorEvent: nil,
                              evidenceValue: nil, evidenceUnit: nil)
        }
        let score = SwingScore(
            tier: .mixed, total: total, detectionQuality: detection,
            mechanicalScore: 0.5, tempoScore: 0.5, consistencyScore: 0.5,
            faults: faultObjs, primaryFault: faults.first)
        let cat = SwingCategory.from(score: score)
        let paths = AnnotatedSwing.buildPaths(swingNumber: n)
        return AnnotatedSwing(
            id: UUID(), swingNumber: n, timestamp: Date(), durationSeconds: 1.5,
            score: score, strengths: [], category: cat, perEvent: [], eventFrames: [],
            handedness: "right", topStrength: nil, topProblem: nil,
            coachingDirectiveKind: nil, spokenFeedback: nil,
            posePath: paths.pose, videoPath: paths.video, thumbnailPath: paths.thumbnail)
    }

    private static func run() {
        func print(_ s: String) { NSLog("%@", s) }   // route to unified log for reliable capture
        print("════════ RetentionSelfTest ════════")
        let cfg = RetentionConfig.standard
        let faultA = SwingFaultID.allCases[0]
        let faultB = SwingFaultID.allCases.count > 1 ? SwingFaultID.allCases[1] : faultA

        // 40-swing session: ascending scores so "best" = highest numbers, with a
        // couple of planted fault swings and one unreadable swing mid-session.
        var swings: [AnnotatedSwing] = []
        for n in 1...40 {
            switch n {
            case 12: swings.append(swing(n, total: 30, faults: [faultA]))      // bad, fault A
            case 18: swings.append(swing(n, total: 25, faults: [faultB]))      // worst, fault B
            case 22: swings.append(swing(n, total: 50, detection: 0.1))        // unreadable
            default: swings.append(swing(n, total: 40 + n))                    // 41…80 ascending
            }
        }
        let userKept: Set<Int> = [5]   // user marked a mid swing

        let working = RetentionPolicy.workingKeepSet(swings, userKept: userKept, cfg: cfg)
        let final = RetentionPolicy.finalKeepSet(swings, userKept: userKept, cfg: cfg)

        var pass = true
        func check(_ label: String, _ cond: Bool) {
            print("  [\(cond ? "PASS" : "FAIL")] \(label)")
            pass = pass && cond
        }

        // ── Working set (during session) ──
        let workingBound = cfg.recentWindow + cfg.workingBestN + cfg.workingWorstN
            + cfg.firstN + 2 + userKept.count
        check("working set bounded (\(working.count) ≤ \(workingBound), ≪ 40)",
              working.count <= workingBound && working.count < 40)
        check("working keeps recent window (33…40)", Set(33...40).isSubset(of: working))
        check("working keeps first-N (1,2,3)", Set([1, 2, 3]).isSubset(of: working))
        check("working keeps user-marked (#5)", working.contains(5))
        check("working keeps a fault rep (#12 or #18)",
              working.contains(12) || working.contains(18))
        check("working drops a mid non-candidate (#15)", !working.contains(15))

        // ── Final keep (on End) ──
        check("final keep is small (\(final.count) ≤ 14, ≪ 40)",
              final.count <= 14 && final.count < 40)
        check("final keeps best (#40, #39)", final.contains(40) && final.contains(39))
        check("final keeps first & last (#1, #40)", final.contains(1) && final.contains(40))
        check("final keeps worst/problem (#18)", final.contains(18))
        check("final keeps per-fault reps (#12 & #18)",
              final.contains(12) && final.contains(18))
        check("final keeps user-marked (#5)", final.contains(5))
        check("final ⊆ working (nothing kept that wasn't a live candidate)",
              final.isSubset(of: working))

        print("  working = \(working.sorted())")
        print("  final   = \(final.sorted())")
        print("════════ RetentionSelfTest: \(pass ? "ALL PASS ✅" : "FAILURES ❌") ════════")
    }
}
