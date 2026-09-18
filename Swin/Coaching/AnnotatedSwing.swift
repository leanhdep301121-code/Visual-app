import Foundation

/// Compact archived record of one swing with the coach's interpretation.
/// Small (~3 KB JSON), suitable for archiving every swing.
///
/// The raw pose / video / metrics live separately under their own paths.
/// This struct is the "what does this swing MEAN" layer.
struct AnnotatedSwing: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    /// 1-indexed position within the session.
    let swingNumber: Int
    let timestamp: Date
    let durationSeconds: Double

    /// Numeric outcome.
    let score: SwingScore
    let strengths: [SwingStrength]
    let category: SwingCategory
    /// Per-event joint angles + frame indices, mirroring Upload-mode detail.
    /// Lets SwingDetailView render the same 8-event metric table.
    /// Mutable because SwingArchive's re-analysis pass overwrites these
    /// with the upload-grade pipeline's output after the per-swing mp4
    /// has been exported. The rest of the fields (faults, score, topX,
    /// etc.) keep the live tracker's values that drove TTS.
    var perEvent: [PerEventMetrics]
    /// 8 event frame indices in the swing's pose buffer, in canonical order.
    /// -1 if the event wasn't detected. Mutable for the same reason as
    /// `perEvent` above.
    var eventFrames: [Int]
    let handedness: String   // "right" | "left", from SwingEvents

    /// Coach interpretation (deterministic; LLM not required).
    let topStrength: String?    // human-readable line, e.g. "Strong torso load — X-factor 42° at top"
    let topProblem: String?     // ditto for the worst fault

    /// What the live coach decided at the moment of this swing — raw value of CoachingDirective.
    let coachingDirectiveKind: String?
    /// What was actually said (TTS final text) at the moment, if any.
    let spokenFeedback: String?

    /// File paths inside the session directory (relative).
    let posePath: String?         // pose.json relative path, always present
    let videoPath: String?        // .mp4 relative path, nil if we didn't keep video for this swing
    let thumbnailPath: String?    // single frame at impact, nil if no video

    static func buildPaths(swingNumber: Int) -> (pose: String, video: String, thumbnail: String) {
        let stem = String(format: "swing_%03d", swingNumber)
        return (
            pose: "pose/\(stem).json",
            video: "video/\(stem).mp4",
            thumbnail: "thumbnails/\(stem).jpg"
        )
    }
}

/// Decision: clean / promising / needsWork / problem / unreadable.
/// Derived deterministically from score + faults so the UI / report never has
/// to re-derive it.
enum SwingCategory: String, Codable, Sendable {
    case clean        // total ≥ 80 AND no faults
    case promising    // 65..79, ≤ 1 mild fault
    case needsWork    // 50..64, faults present
    case problem      // < 50, severe faults
    case unreadable   // detection too low — don't draw conclusions

    static func from(score: SwingScore) -> SwingCategory {
        if score.detectionQuality < 0.2 { return .unreadable }
        let s = score.total
        let hasSevereFault = score.faults.contains(where: { $0.severity >= 0.6 })
        if s >= 80 && score.faults.isEmpty { return .clean }
        if s >= 65 && !hasSevereFault { return .promising }
        if s >= 50 { return .needsWork }
        return .problem
    }
}

/// Composer — produces an AnnotatedSwing from raw inputs.
/// Pure function; no I/O. Persisting is the SwingArchive's job.
struct SwingAnnotator {
    private let strengthDetector = SwingStrengthDetector()

    func annotate(
        report: SwingReport,
        score: SwingScore,
        swingNumber: Int,
        directiveKind: String? = nil,
        spokenFeedback: String? = nil,
        videoPath: String? = nil,
        thumbnailPath: String? = nil
    ) -> AnnotatedSwing {
        let strengths = strengthDetector.detect(report: report)
        let category = SwingCategory.from(score: score)
        let paths = AnnotatedSwing.buildPaths(swingNumber: swingNumber)
        // Optimistically record the conventional relative paths. SwingDetailView
        // checks `FileManager.fileExists` at read time so it gracefully renders
        // "no video" if the clip ended up not being written for any reason.
        let resolvedVideoPath = videoPath ?? paths.video
        let resolvedThumbnailPath = thumbnailPath ?? paths.thumbnail

        let duration = report.poseFrames.count > 0 ? Double(report.poseFrames.count) / 30.0 : 0

        return AnnotatedSwing(
            id: report.id,
            swingNumber: swingNumber,
            timestamp: report.timestamp,
            durationSeconds: duration,
            score: score,
            strengths: strengths,
            category: category,
            perEvent: report.perEvent,
            eventFrames: report.events.frames,
            handedness: report.events.handedness == .right ? "right" : "left",
            topStrength: buildTopStrengthLine(strengths: strengths),
            topProblem: buildTopProblemLine(faults: score.faults),
            coachingDirectiveKind: directiveKind,
            spokenFeedback: spokenFeedback,
            posePath: paths.pose,
            videoPath: resolvedVideoPath,
            thumbnailPath: resolvedThumbnailPath
        )
    }

    private func buildTopStrengthLine(strengths: [SwingStrength]) -> String? {
        guard let s = strengths.first else { return nil }
        if let val = s.evidenceValue, let unit = s.evidenceUnit {
            return "\(s.id.label) — \(Int(val.rounded())) \(unit)"
        }
        return s.id.label
    }

    private func buildTopProblemLine(faults: [SwingFault]) -> String? {
        guard let f = faults.first else { return nil }
        if let val = f.evidenceValue, let unit = f.evidenceUnit {
            return "\(f.id.label) — \(Int(val.rounded())) \(unit)"
        }
        return f.id.label
    }
}
