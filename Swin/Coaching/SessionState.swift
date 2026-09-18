import Foundation

/// In-memory state of a coaching session. Pure data — no UI, no LLM,
/// no persistence. Just the counters the coach needs to decide what to say.
///
/// Lifecycle:
///   - `SessionCoach.start()` creates a new SessionState
///   - Each new swing → `ingest(score:)` mutates counters
///   - `SessionCoach.close()` finalizes into a `SessionReport`
struct SessionState: Sendable {
    let startedAt: Date
    var swings: [SwingScore] = []

    /// Consecutive count of recent good swings (≥ goodScoreThreshold).
    /// Resets to 0 on any bad/mid swing.
    var goodStreak: Int = 0

    /// For each known fault, the consecutive streak of recent swings exhibiting it.
    /// If a swing doesn't show that fault, its streak goes back to 0.
    /// LLM reads this to know "this is the 3rd time over_the_top showed up".
    var faultStreak: [SwingFaultID: Int] = [:]

    /// If a fault has appeared in N consecutive swings, the coach locks onto it —
    /// subsequent feedback narrows to "fix this one thing". Resets when the fault
    /// disappears for `focusReleaseStreak` consecutive swings.
    var focusedFault: SwingFaultID? = nil
    var focusReleaseCountdown: Int = 0

    /// How many consecutive swings we've been *reinforcing* the current focus
    /// without it clearing or the swing improving. When this crosses the
    /// coach's `stuckThreshold` we stop repeating the same one-line fix and
    /// drop down to an easy analogy + drill instead (the "student is stuck and
    /// getting frustrated" path the coaching expert asked for). Reset on lock,
    /// improvement, release, or after a drill is delivered.
    var focusReinforceCount: Int = 0

    /// The fault we last *called out by name* while not yet formally focus-
    /// locked. Gives pre-lock stickiness in "work on everything" mode: we keep
    /// coaching the same fault swing-to-swing instead of naming a different
    /// problem every swing (which testers found confusing). Cleared when that
    /// fault stops appearing.
    var announcedFault: SwingFaultID? = nil

    /// Severity (0…1) of the focused fault on each swing since we locked onto
    /// it. Lets the coach judge progress against the player's OWN baseline
    /// instead of a fixed pass/fail line — "did they get better since I started
    /// coaching this", "have they plateaued at their personal best". Reset on
    /// lock / release. Empty when nothing is focused.
    var focusSeverityHistory: [Double] = []

    /// Last 5 totals — for the "rolling avg" in LLM context.
    var rollingScores: [Int] { swings.suffix(5).map(\.total) }

    var avgScore: Double {
        guard !swings.isEmpty else { return 0 }
        return Double(swings.reduce(0) { $0 + $1.total }) / Double(swings.count)
    }
}

/// Snapshot of session state passed into the LLM as structured context.
/// Built deterministically from `SessionState` at the moment of a coaching call.
struct CoachingContext: Codable, Sendable {
    let swingNumber: Int
    let currentScore: Int
    let currentFaults: [String]            // fault IDs sorted strongest-first
    let primaryFault: String?
    let faultStreak: [String: Int]         // only entries with streak > 0
    let goodStreak: Int
    let focusedFault: String?              // sticky fault the coach is currently coaching
    let last3Scores: [Int]
    let sessionAvgScore: Double
    let isFirstSwing: Bool
}
