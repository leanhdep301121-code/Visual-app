import Foundation

/// Generates a SessionReport from a SessionStats.
///
/// Tries cloud LLM first (DeepSeek), streams 6 JSON fields progressively to
/// the caller via `onProgress`. If the cloud call fails / times out, falls
/// back to the deterministic `SessionReport.fallback(from:)`.
final class SessionReportGenerator: @unchecked Sendable {
    private let cloud: CloudLLMService?

    init(cloud: CloudLLMService?) {
        self.cloud = cloud
    }

    /// Generate the report. Calls `onProgress` on the main actor every time a
    /// streamed delta arrives, so the UI can render fields as they fill.
    /// Returns the final report.
    func generate(
        stats: SessionStats,
        onProgress: @escaping @MainActor (SessionReport) -> Void
    ) async -> SessionReport {
        // Always start with the deterministic fallback so the UI has
        // something to show in case streaming never starts. We replace fields
        // with LLM output as they arrive.
        var report = SessionReport.fallback(from: stats)
        await MainActor.run { onProgress(report) }

        guard let cloud else {
            // No LLM available — fallback is the final answer.
            return report
        }

        do {
            let (system, user) = Self.buildPrompt(stats: stats)
            try await cloud.streamSessionReport(
                systemPrompt: system,
                userPrompt: user,
                onPartialJSON: { partial in
                    // Merge new fields into the running report; ignore parse errors.
                    if let parsed = Self.parsePartialJSON(partial) {
                        report = Self.merge(into: report, from: parsed)
                        Task { @MainActor in onProgress(report) }
                    }
                }
            )
            report.isComplete = true
            await MainActor.run { onProgress(report) }
        } catch {
            print("[SessionReportGenerator] cloud failed: \(error.localizedDescription) — using fallback")
            // report is already the fallback
            report.isComplete = true
            await MainActor.run { onProgress(report) }
        }
        return report
    }

    // MARK: - prompt construction

    private static func buildPrompt(stats: SessionStats) -> (system: String, user: String) {
        let system = """
        You are a PGA golf coach writing a brief session report. Output JSON ONLY (no prose, no markdown) with EXACTLY these six string fields, in this order, each ≤30 words, in plain English. Address the student as "you". Cite numbers only if they appear in the input — don't invent.

        {
          "headline": "<one-line takeaway>",
          "scoreSummary": "<short numeric callout: swings, avg, peak>",
          "topStrength": "<what the player did well, with a specific metric>",
          "topProblemWithFix": "<the worst recurring problem AND one concrete cue to fix it>",
          "sessionProgress": "<how the session evolved: did they get better, worse, steady?>",
          "nextSessionGoal": "<one actionable goal for next time>"
        }
        """
        var lines: [String] = []
        lines.append("=== Session ===")
        lines.append("swings: \(stats.swingCount)")
        lines.append("avg: \(Int(stats.avgScore.rounded()))  median: \(stats.medianScore)  std: \(Int(stats.stdScore.rounded()))")
        lines.append("range: \(stats.minScore)..\(stats.maxScore)")
        if let dur = stats.durationMinutes {
            lines.append("duration: \(Int(dur.rounded())) min")
        }
        // Categories
        let cats = stats.categoryCounts.sorted(by: { $0.value > $1.value })
            .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        if !cats.isEmpty { lines.append("categories: \(cats)") }
        // Faults: top 3
        if !stats.faultRates.isEmpty {
            lines.append("=== Faults (top by count) ===")
            for fr in stats.faultRates.prefix(3) {
                let pct = Int((fr.rate * 100).rounded())
                let sev = String(format: "%.2f", fr.avgSeverity)
                lines.append("- \(fr.id): \(fr.count)/\(fr.totalSwings) (\(pct)%, sev \(sev))")
            }
        }
        // Strengths: top 3
        if !stats.strengthRates.isEmpty {
            lines.append("=== Strengths (top by count) ===")
            for sr in stats.strengthRates.prefix(3) {
                let pct = Int((sr.rate * 100).rounded())
                lines.append("- \(sr.id): \(sr.count)/\(sr.totalSwings) (\(pct)%)")
            }
        }
        // In-session progression
        lines.append("=== In-session progress ===")
        lines.append("firstHalfAvg: \(Int(stats.firstHalfAvg.rounded()))  secondHalfAvg: \(Int(stats.secondHalfAvg.rounded()))  delta: \(Int(stats.improvementDelta.rounded()))")
        let bigChanges = stats.faultRateChange.prefix(3)
        for fd in bigChanges where abs(fd.deltaRate) > 0.1 {
            let firstPct = Int((fd.firstHalfRate * 100).rounded())
            let secondPct = Int((fd.secondHalfRate * 100).rounded())
            let arrow = fd.deltaRate > 0 ? "↑" : "↓"
            lines.append("- \(fd.id): \(firstPct)% → \(secondPct)% \(arrow)")
        }
        // Cross-session
        if let prev = stats.vsPreviousSession {
            lines.append("=== vs previous session ===")
            lines.append("previous avg: \(Int(prev.previousAvgScore.rounded()))  delta: \(Int(prev.avgScoreDelta.rounded()))")
            for fd in prev.topFaultRateChange.prefix(3) {
                let firstPct = Int((fd.firstHalfRate * 100).rounded())
                let secondPct = Int((fd.secondHalfRate * 100).rounded())
                lines.append("- \(fd.id): \(firstPct)% (prev) → \(secondPct)% (now)")
            }
        }
        return (system, lines.joined(separator: "\n"))
    }

    // MARK: - partial JSON parsing
    // The LLM streams JSON character-by-character. We try to parse what we have
    // so far; if it's incomplete, we extract any complete top-level string
    // fields ("headline": "...") via a forgiving regex.

    private static func parsePartialJSON(_ raw: String) -> SessionReport? {
        // First try strict JSON.
        if let data = raw.data(using: .utf8),
           let report = try? JSONDecoder().decode(SessionReport.self, from: data) {
            return report
        }
        // Fall back to field-by-field regex extraction.
        let fields = ["headline", "scoreSummary", "topStrength",
                       "topProblemWithFix", "sessionProgress", "nextSessionGoal"]
        var partial = SessionReport.empty
        var anyFound = false
        for field in fields {
            // Look for "field": "value"  where value may be partial.
            let pattern = #""\#(field)"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)""#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = raw as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = regex.firstMatch(in: raw, range: range), m.numberOfRanges >= 2 {
                let value = ns.substring(with: m.range(at: 1))
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\n", with: "\n")
                anyFound = true
                switch field {
                case "headline": partial.headline = value
                case "scoreSummary": partial.scoreSummary = value
                case "topStrength": partial.topStrength = value
                case "topProblemWithFix": partial.topProblemWithFix = value
                case "sessionProgress": partial.sessionProgress = value
                case "nextSessionGoal": partial.nextSessionGoal = value
                default: break
                }
            }
        }
        return anyFound ? partial : nil
    }

    /// Merge non-empty fields from `update` into `into`, returning the merged copy.
    private static func merge(into base: SessionReport, from update: SessionReport) -> SessionReport {
        var r = base
        if !update.headline.isEmpty { r.headline = update.headline }
        if !update.scoreSummary.isEmpty { r.scoreSummary = update.scoreSummary }
        if !update.topStrength.isEmpty { r.topStrength = update.topStrength }
        if !update.topProblemWithFix.isEmpty { r.topProblemWithFix = update.topProblemWithFix }
        if !update.sessionProgress.isEmpty { r.sessionProgress = update.sessionProgress }
        if !update.nextSessionGoal.isEmpty { r.nextSessionGoal = update.nextSessionGoal }
        return r
    }
}
