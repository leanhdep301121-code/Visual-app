import Foundation

/// Compute `SessionStats` from the per-swing AnnotatedSwing list.
/// Pure code, no LLM. Same input → same output.
///
/// `summarize(_:previous:)` is the entry point — pass the current session's
/// swings, optionally the previous session's stats for cross-session compare.
struct SessionAnalyzer {
    func summarize(
        sessionID: String,
        startedAt: Date,
        endedAt: Date?,
        swings: [AnnotatedSwing],
        previousSession: SessionStats? = nil
    ) -> SessionStats {
        // ---- 0. Sort by swing number to guarantee chronological order ----
        let ordered = swings.sorted(by: { $0.swingNumber < $1.swingNumber })
        let n = ordered.count

        let durationMin: Double? = {
            guard let end = endedAt else { return nil }
            return end.timeIntervalSince(startedAt) / 60.0
        }()

        guard n > 0 else {
            // Edge case: empty session.
            return SessionStats(
                sessionID: sessionID,
                startedAt: startedAt,
                endedAt: endedAt,
                durationMinutes: durationMin,
                swingCount: 0,
                avgScore: 0, medianScore: 0, stdScore: 0, minScore: 0, maxScore: 0,
                categoryCounts: [:],
                faultRates: [], strengthRates: [],
                firstHalfAvg: 0, secondHalfAvg: 0, improvementDelta: 0,
                faultRateChange: [],
                vsPreviousSession: nil,
                bestSwingIDs: [], worstSwingIDs: [],
                representativeFaultSwingID: nil,
                representativeStrengthSwingID: nil
            )
        }

        // ---- 1. Basic descriptive stats over total score ----
        let totals = ordered.map { $0.score.total }
        let avg = Double(totals.reduce(0, +)) / Double(n)
        let std = stddev(values: totals, mean: avg)
        let median = totals.sorted()[n / 2]
        let minS = totals.min() ?? 0
        let maxS = totals.max() ?? 0

        // ---- 2. Category breakdown ----
        var catCounts: [String: Int] = [:]
        for s in ordered {
            catCounts[s.category.rawValue, default: 0] += 1
        }

        // ---- 3. Fault rates (count + avg severity) ----
        var faultCount: [SwingFaultID: Int] = [:]
        var faultSevSum: [SwingFaultID: Double] = [:]
        for s in ordered {
            for f in s.score.faults {
                faultCount[f.id, default: 0] += 1
                faultSevSum[f.id, default: 0] += f.severity
            }
        }
        let faultRates = faultCount.map { fid, cnt -> SessionStats.FaultRate in
            let avgSev = (faultSevSum[fid] ?? 0) / Double(cnt)
            return .init(id: fid.rawValue, count: cnt, totalSwings: n, avgSeverity: avgSev)
        }.sorted(by: { $0.count > $1.count })

        // ---- 4. Strength rates ----
        var strengthCount: [SwingStrengthID: Int] = [:]
        var strengthConfSum: [SwingStrengthID: Double] = [:]
        for s in ordered {
            for st in s.strengths {
                strengthCount[st.id, default: 0] += 1
                strengthConfSum[st.id, default: 0] += st.confidence
            }
        }
        let strengthRates = strengthCount.map { sid, cnt -> SessionStats.StrengthRate in
            let avgConf = (strengthConfSum[sid] ?? 0) / Double(cnt)
            return .init(id: sid.rawValue, count: cnt, totalSwings: n, avgConfidence: avgConf)
        }.sorted(by: { $0.count > $1.count })

        // ---- 5. In-session improvement (split in half) ----
        let half = n / 2
        let firstHalf = Array(ordered.prefix(half == 0 ? 1 : half))
        let secondHalf = Array(ordered.suffix(n - firstHalf.count))
        let firstAvg = avgScoreOf(firstHalf)
        let secondAvg = avgScoreOf(secondHalf)

        let faultDeltas = SwingFaultID.allCases.compactMap { fid -> SessionStats.FaultDelta? in
            let firstHits = firstHalf.filter { swing in swing.score.faults.contains(where: { $0.id == fid }) }.count
            let secondHits = secondHalf.filter { swing in swing.score.faults.contains(where: { $0.id == fid }) }.count
            // Only emit faults that appeared at least once across the whole session.
            guard firstHits + secondHits > 0 else { return nil }
            return .init(
                id: fid.rawValue,
                firstHalfRate: firstHalf.isEmpty ? 0 : Double(firstHits) / Double(firstHalf.count),
                secondHalfRate: secondHalf.isEmpty ? 0 : Double(secondHits) / Double(secondHalf.count)
            )
        }
        .sorted(by: { abs($0.deltaRate) > abs($1.deltaRate) })

        // ---- 6. Cross-session compare ----
        let vsPrev: SessionStats.SessionDelta? = previousSession.map { prev in
            // Build per-fault delta against previous session.
            var prevRates: [String: Double] = [:]
            for fr in prev.faultRates {
                prevRates[fr.id] = fr.rate
            }
            var curRates: [String: Double] = [:]
            for fr in faultRates {
                curRates[fr.id] = fr.rate
            }
            let allIDs = Set(prevRates.keys).union(curRates.keys)
            let deltas = allIDs.map { fid -> SessionStats.FaultDelta in
                .init(
                    id: fid,
                    firstHalfRate: prevRates[fid] ?? 0,
                    secondHalfRate: curRates[fid] ?? 0
                )
            }.sorted(by: { abs($0.deltaRate) > abs($1.deltaRate) })

            return .init(
                previousSessionID: prev.sessionID,
                previousAvgScore: prev.avgScore,
                avgScoreDelta: avg - prev.avgScore,
                topFaultRateChange: Array(deltas.prefix(5))
            )
        }

        // ---- 7. Representative picks ----
        let sortedByScore = ordered.sorted(by: { $0.score.total > $1.score.total })
        let bestIDs = sortedByScore.prefix(3).map(\.id)
        let worstIDs = sortedByScore.reversed().prefix(3).map(\.id)

        // Representative fault swing: most severe instance of the most common fault.
        let representativeFaultID: UUID? = {
            guard let top = faultRates.first?.id,
                  let topFaultEnum = SwingFaultID(rawValue: top)
            else { return nil }
            var worstSeverity: Double = -1
            var pickedID: UUID? = nil
            for s in ordered {
                if let f = s.score.faults.first(where: { $0.id == topFaultEnum }) {
                    if f.severity > worstSeverity {
                        worstSeverity = f.severity
                        pickedID = s.id
                    }
                }
            }
            return pickedID
        }()

        // Representative strength swing: highest-confidence instance of the most common strength.
        let representativeStrengthID: UUID? = {
            guard let top = strengthRates.first?.id,
                  let topStrengthEnum = SwingStrengthID(rawValue: top)
            else { return nil }
            var bestConf: Double = -1
            var pickedID: UUID? = nil
            for s in ordered {
                if let strg = s.strengths.first(where: { $0.id == topStrengthEnum }) {
                    if strg.confidence > bestConf {
                        bestConf = strg.confidence
                        pickedID = s.id
                    }
                }
            }
            return pickedID
        }()

        return SessionStats(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMinutes: durationMin,
            swingCount: n,
            avgScore: avg,
            medianScore: median,
            stdScore: std,
            minScore: minS,
            maxScore: maxS,
            categoryCounts: catCounts,
            faultRates: faultRates,
            strengthRates: strengthRates,
            firstHalfAvg: firstAvg,
            secondHalfAvg: secondAvg,
            improvementDelta: secondAvg - firstAvg,
            faultRateChange: faultDeltas,
            vsPreviousSession: vsPrev,
            bestSwingIDs: Array(bestIDs),
            worstSwingIDs: Array(worstIDs),
            representativeFaultSwingID: representativeFaultID,
            representativeStrengthSwingID: representativeStrengthID
        )
    }

    // MARK: - helpers

    private func stddev(values: [Int], mean: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let variance = values.reduce(0.0) { acc, v in
            acc + (Double(v) - mean) * (Double(v) - mean)
        } / Double(values.count - 1)
        return variance.squareRoot()
    }

    private func avgScoreOf(_ swings: [AnnotatedSwing]) -> Double {
        guard !swings.isEmpty else { return 0 }
        let total = swings.reduce(0) { $0 + $1.score.total }
        return Double(total) / Double(swings.count)
    }
}
