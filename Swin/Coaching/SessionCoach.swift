import Foundation
import Observation

/// Maintains live SessionState across swings and decides WHAT to say + WHEN.
///
/// What it does NOT do:
///   - Build the spoken sentence (that's the LLM's job — we call a closure)
///   - Play TTS (callers wire that)
///   - Persist anything
///
/// The flow per new swing:
///   1. ingest(score:) updates counters
///   2. decide() returns a `CoachingDirective` enum saying which kind of
///      feedback to produce (good, ignore, fix, fixed, focus)
///   3. caller resolves the directive into a sentence — either via the
///      injected LLM closure or via local templates
@Observable
final class SessionCoach: @unchecked Sendable {
    private(set) var state: SessionState = .init(startedAt: Date())

    // ---- Tunables ----
    /// Score at/above which a swing counts as "good" for streak / praise.
    var goodScoreThreshold: Int = 70
    /// Score below which a swing counts as "bad" → coaching kicks in.
    var badScoreThreshold: Int = 55
    /// A fault that appears in this many consecutive swings becomes the focus.
    var focusLockStreak: Int = 2
    /// A focused fault that misses this many consecutive swings is released.
    var focusReleaseStreak: Int = 2
    /// After this many swings of reinforcing the SAME focus with no clearing /
    /// no improvement, stop repeating the one-line fix and switch to an easy
    /// analogy + drill (the "they're stuck and frustrated" downgrade). Testers
    /// reported the coach just repeating itself and the player feeling they
    /// could never pass — this is the escape hatch a real coach uses.
    var stuckThreshold: Int = 3

    /// Start a session. `focus` (the issue the user chose on the onboarding
    /// screen, nil = "work on everything") is seeded as the active focus so the
    /// coach commits to it from swing 1 instead of waiting to auto-detect it.
    func start(focus: SwingFaultID? = nil) {
        state = SessionState(startedAt: Date())
        state.focusedFault = focus
    }

    /// Ingest one finished swing. Mutates state and returns the directive the
    /// caller should turn into a sentence.
    func ingest(score: SwingScore) -> CoachingDirective {
        let wasFirst = state.swings.isEmpty
        state.swings.append(score)

        // Update fault streaks for every known fault.
        let activeFaults = Set(score.faults.map(\.id))
        for fid in SwingFaultID.allCases {
            if activeFaults.contains(fid) {
                state.faultStreak[fid, default: 0] += 1
            } else {
                state.faultStreak[fid] = 0
            }
        }

        // Good-streak counter.
        if score.total >= goodScoreThreshold {
            state.goodStreak += 1
        } else {
            state.goodStreak = 0
        }

        let directive = decideDirective(score: score, wasFirst: wasFirst)
        // Side effects of the directive on focus state happen here so callers
        // don't have to.
        applyFocusSideEffect(directive: directive, score: score)
        return directive
    }

    /// Read-only snapshot suitable for an LLM prompt.
    func contextSnapshot() -> CoachingContext {
        let current = state.swings.last
        let faultStr = state.faultStreak.filter { $0.value > 0 }
            .reduce(into: [String: Int]()) { $0[$1.key.rawValue] = $1.value }
        return CoachingContext(
            swingNumber: state.swings.count,
            currentScore: current?.total ?? 0,
            currentFaults: current?.faults.map(\.id.rawValue) ?? [],
            primaryFault: current?.primaryFault?.rawValue,
            faultStreak: faultStr,
            goodStreak: state.goodStreak,
            focusedFault: state.focusedFault?.rawValue,
            last3Scores: Array(state.swings.suffix(3).map(\.total)),
            sessionAvgScore: state.avgScore,
            isFirstSwing: state.swings.count == 1
        )
    }

    // MARK: - decision tree

    private func decideDirective(score: SwingScore, wasFirst: Bool) -> CoachingDirective {
        // Bad detection → don't pretend we have signal.
        if score.detectionQuality < 0.35 {
            return .skipUnreadable
        }

        // We've been coaching a focused fault. Check whether it cleared or persists.
        if let focus = state.focusedFault {
            let stillPresent = score.faults.contains(where: { $0.id == focus })
            if stillPresent {
                // STICKY: as long as the focused fault is still present, keep
                // coaching IT — not whatever is momentarily this swing's top
                // root (jumping every swing confused testers). We judge progress
                // against the PLAYER'S OWN baseline severity, not a fixed bar:
                // bodies differ and the absolute thresholds can be unrealistic
                // (a tour pro can "fail" a 2D-measured X-factor cutoff), so the
                // coach adapts to the person instead of nagging a dead line.
                let cur = severity(of: focus, in: score)
                let hist = state.focusSeverityHistory          // BEFORE this swing
                let baseline = hist.first ?? cur               // severity when we locked on
                let best = hist.min() ?? cur                   // their best so far
                let improvedFromBaseline = baseline - cur      // >0 = better than start
                let atOrNearBest = cur <= best + 0.03

                // 1) They got better than where they started AND are at/near
                //    their personal best this swing → celebrate the improvement
                //    (resets the "stuck" counter so we don't nag).
                if improvedFromBaseline >= 0.12, atOrNearBest {
                    return .focusImproving(fault: focus, score: score.total)
                }
                // 2) We've reinforced the same cue for a few swings with no
                //    further progress → they've plateaued.
                if state.focusReinforceCount + 1 >= stuckThreshold {
                    if improvedFromBaseline >= 0.10 {
                        // They put in work and improved, just can't squeeze more
                        // out right now. Estimate this IS their best for now —
                        // accept it, praise it, and move on rather than nag a
                        // possibly-unrealistic absolute bar.
                        return .focusBestEffort(fault: focus)
                    }
                    // No improvement at all despite trying → the cue isn't
                    // landing. Switch to an easy analogy + drill (and reassure).
                    return .focusStuck(fault: focus)
                }
                return .focusReinforce(fault: focus,
                                       streak: state.faultStreak[focus, default: 1])
            } else {
                // Fault skipped this swing — see if it's been gone long enough.
                if state.focusReleaseCountdown + 1 >= focusReleaseStreak {
                    return .focusReleased(fault: focus, replacementScore: score.total)
                } else {
                    // One free pass; still pay attention next swing.
                    return .focusWaiting(fault: focus)
                }
            }
        }

        // No focus yet. Lock in if any fault has stuck for `focusLockStreak` swings.
        if let lockTarget = state.faultStreak
            .filter({ $0.value >= focusLockStreak })
            .max(by: { $0.value < $1.value })?.key
        {
            return .focusLocked(fault: lockTarget,
                                streak: state.faultStreak[lockTarget, default: focusLockStreak])
        }

        // Good swing path.
        if score.total >= goodScoreThreshold {
            if state.goodStreak >= 3 {
                return .goodStreak(count: state.goodStreak, score: score.total)
            } else {
                return .goodOne(score: score.total)
            }
        }

        // Bad swing — call out a fault. Prefer the one we already named last
        // swing if it's still here (pre-lock stickiness), so "work on
        // everything" mode commits to one problem for a few swings instead of
        // announcing a different fault every single time.
        if score.total < badScoreThreshold {
            if let prior = state.announcedFault,
               let f = score.faults.first(where: { $0.id == prior }) {
                return .fixOne(fault: prior, severity: f.severity)
            }
            if let pf = score.primaryFault {
                return .fixOne(fault: pf, severity: score.faults.first?.severity ?? 0)
            }
        }

        // Middle ground.
        if wasFirst {
            return .firstSwingNeutral(score: score.total)
        }
        return .neutralProgress(score: score.total)
    }

    private func applyFocusSideEffect(directive: CoachingDirective, score: SwingScore) {
        switch directive {
        case .focusLocked(let fault, _):
            state.focusedFault = fault
            state.announcedFault = fault
            state.focusReleaseCountdown = 0
            state.focusReinforceCount = 0
            state.focusSeverityHistory = [severity(of: fault, in: score)]
        case .focusReinforce(let fault, _):
            state.focusReleaseCountdown = 0
            state.focusReinforceCount += 1
            state.announcedFault = fault
            state.focusSeverityHistory.append(severity(of: fault, in: score))
        case .focusStuck(let fault):
            // We just delivered the analogy + drill. Reset the stuck counter so
            // we give that new feel a few swings before escalating again (and
            // don't repeat the drill every single swing).
            state.focusReleaseCountdown = 0
            state.focusReinforceCount = 0
            state.announcedFault = fault
            state.focusSeverityHistory.append(severity(of: fault, in: score))
        case .focusImproving(let fault, _):
            // Progress — clear the stuck counter so a later plateau starts fresh.
            state.focusReleaseCountdown = 0
            state.focusReinforceCount = 0
            state.focusSeverityHistory.append(severity(of: fault, in: score))
        case .focusBestEffort:
            // Accepted their best on this one — release and move on so the next
            // swings can surface (and lock onto) the next-most-important thing.
            state.focusedFault = nil
            state.announcedFault = nil
            state.focusReleaseCountdown = 0
            state.focusReinforceCount = 0
            state.focusSeverityHistory = []
        case .focusWaiting:
            state.focusReleaseCountdown += 1
        case .focusReleased:
            state.focusedFault = nil
            state.announcedFault = nil
            state.focusReleaseCountdown = 0
            state.focusReinforceCount = 0
            state.focusSeverityHistory = []
        case .fixOne(let fault, _):
            // Remember what we called out so the next swing can stick with it.
            state.announcedFault = fault
        default:
            break
        }
    }

    /// Severity (0…1) of a specific fault in a swing's score, or 0 if absent.
    private func severity(of fault: SwingFaultID, in score: SwingScore) -> Double {
        score.faults.first(where: { $0.id == fault })?.severity ?? 0
    }
}

// MARK: - directive enum
// The coach's output. Each case carries enough data for the caller to either
// look up a local template or build an LLM prompt.

enum CoachingDirective: Sendable {
    /// Detection was too noisy — don't speak.
    case skipUnreadable

    /// First swing of the session: gentle factual callout.
    case firstSwingNeutral(score: Int)

    /// Lonely good swing: short praise.
    case goodOne(score: Int)

    /// Multiple good swings in a row — bigger reinforcement.
    case goodStreak(count: Int, score: Int)

    /// Single bad swing without context lock: name the worst fault.
    case fixOne(fault: SwingFaultID, severity: Double)

    /// Fault has appeared `streak` times in a row — start coaching it explicitly.
    case focusLocked(fault: SwingFaultID, streak: Int)

    /// We're coaching a focus fault and it appeared again this swing.
    case focusReinforce(fault: SwingFaultID, streak: Int)

    /// The focus fault has persisted through several reinforcements with no
    /// improvement — the student is stuck. Drop the repeated one-liner and give
    /// an easy analogy + a concrete drill, with reassurance (not "凶").
    case focusStuck(fault: SwingFaultID)

    /// The player improved this fault from their starting point and has now
    /// plateaued at their personal best — they've done about as well as their
    /// body allows for now. Acknowledge the work, praise it, and MOVE ON instead
    /// of nagging a fixed bar they may never hit. Releases the focus.
    case focusBestEffort(fault: SwingFaultID)

    /// Focused fault still present, but the swing as a whole improved
    /// (score crossed good-threshold or jumped vs prior). Acknowledge the
    /// progress rather than just nagging the fault again.
    case focusImproving(fault: SwingFaultID, score: Int)

    /// Focus fault didn't appear this swing — partial reset, give a beat.
    case focusWaiting(fault: SwingFaultID)

    /// Focus fault has been absent long enough — celebrate + release.
    case focusReleased(fault: SwingFaultID, replacementScore: Int)

    /// Middle-of-the-road swing, no clear story. Light callout or stay quiet.
    case neutralProgress(score: Int)
}

extension CoachingDirective {
    /// Whether to speak at all for this directive. Some (skipUnreadable,
    /// neutralProgress, focusWaiting) stay silent to avoid coach overload.
    var shouldSpeak: Bool {
        switch self {
        case .skipUnreadable, .neutralProgress:
            return false
        // .focusWaiting used to be silent. Speak a short encouragement
        // instead — keeps rhythm when the fault loosens for a single swing.
        default:
            return true
        }
    }
}
