import Foundation

/// Aggregated, LLM-prompt-ready summary of one session.
/// Pure data; produced by `SessionAnalyzer.summarize(_:)`.
/// Stays well under 1 KB JSON, so we can ship the whole thing into a single
/// LLM prompt without burning tokens.
struct SessionStats: Codable, Sendable {
    /// Foreign keys / references.
    let sessionID: String
    let startedAt: Date
    let endedAt: Date?
    let durationMinutes: Double?

    // ---- Basic descriptive stats ----
    let swingCount: Int
    let avgScore: Double
    let medianScore: Int
    let stdScore: Double
    let minScore: Int
    let maxScore: Int

    // ---- Category breakdown ----
    /// Counts by SwingCategory (clean, promising, needsWork, problem, unreadable).
    /// Keys are raw values of SwingCategory.
    let categoryCounts: [String: Int]

    // ---- Fault / strength frequency ----
    /// Faults sorted by `count` desc. Each entry: id rawValue, # of swings,
    /// avg severity across those swings.
    let faultRates: [FaultRate]
    let strengthRates: [StrengthRate]

    // ---- In-session improvement ----
    /// Split the session in half (by swing order). First half = early swings,
    /// second half = later swings. Compare avgs.
    let firstHalfAvg: Double
    let secondHalfAvg: Double
    /// secondHalfAvg − firstHalfAvg. Positive = improved.
    let improvementDelta: Double
    /// For each fault, its rate in (firstHalf, secondHalf). Useful for
    /// "you fixed sway midway through the session" callouts.
    let faultRateChange: [FaultDelta]

    // ---- Cross-session compare (optional) ----
    let vsPreviousSession: SessionDelta?

    // ---- Representative picks (UUIDs into the AnnotatedSwing list) ----
    let bestSwingIDs: [UUID]                // top 3 by total score
    let worstSwingIDs: [UUID]               // bottom 3 by total score
    let representativeFaultSwingID: UUID?   // worst case of the dominant fault
    let representativeStrengthSwingID: UUID? // best case of the dominant strength

    struct FaultRate: Codable, Sendable {
        let id: String          // SwingFaultID rawValue
        let count: Int
        let totalSwings: Int
        let avgSeverity: Double
        var rate: Double { totalSwings == 0 ? 0 : Double(count) / Double(totalSwings) }
    }

    struct StrengthRate: Codable, Sendable {
        let id: String          // SwingStrengthID rawValue
        let count: Int
        let totalSwings: Int
        let avgConfidence: Double
        var rate: Double { totalSwings == 0 ? 0 : Double(count) / Double(totalSwings) }
    }

    struct FaultDelta: Codable, Sendable {
        let id: String
        let firstHalfRate: Double
        let secondHalfRate: Double
        var deltaRate: Double { secondHalfRate - firstHalfRate }
    }

    struct SessionDelta: Codable, Sendable {
        let previousSessionID: String
        let previousAvgScore: Double
        let avgScoreDelta: Double         // current - previous, signed
        let topFaultRateChange: [FaultDelta]   // previous rate vs current rate, ranked
    }
}
