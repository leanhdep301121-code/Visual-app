import Foundation

/// Dynamic video-retention policy (§3.5 of the Xbotgo handoff).
///
/// The phone can't keep an mp4 for every swing — a long range session is
/// hundreds of swings × a few MB each. But which swings are worth keeping
/// (best / representative problems / first-last for progress) is only fully
/// known when the session ENDS, while video has to be recorded live. The
/// resolution: keep a BOUNDED running candidate set during the session, then
/// prune to a small final keep-set on End.
///
/// Three layers (the data layer — pose + annotated JSON, ~100 KB/swing — is
/// ALWAYS kept by SwingArchive regardless, so analysis stays reproducible even
/// after a swing's video is pruned):
///
///   1. Working set (during session, bounded ≈20-30 clips): recent rolling
///      window (replay / gimbal) + running best-N + first-N + one worst
///      example per primary fault + user-marked. Clips that age out of all of
///      these are deleted mid-session so disk stays bounded.
///   2. Final keep (on End, ≈8-12 clips): best-N + worst-N + one per primary
///      fault + first & last + user-marked. Everything else's video is pruned
///      (its JSON stays).
///   3. Cross-session cap: only the most recent K sessions keep video at all;
///      older sessions degrade to JSON + (their already-kept) clips removed.
///
/// All functions here are PURE — they take the session's AnnotatedSwings (read
/// off disk) and return the set of swing NUMBERS whose video should exist.
/// SwingArchive owns the disk and does the actual export-gating / deletion.
struct RetentionConfig: Sendable {
    // During-session working set. NB: the working set is deliberately a
    // SUPERSET of everything `finalKeepSet` can want (workingBestN ≥ finalBestN,
    // workingWorstN ≥ finalWorstN, plus per-fault reps + first-N). That makes
    // "final ⊆ working" an invariant, so a swing the End-prune wants to keep
    // was never evicted mid-session — i.e. it actually still has its clip.
    /// Rolling window of most-recent swings always kept for replay (the
    /// gimbal "show me that last one" path needs these). Doc suggests 5-10.
    var recentWindow: Int = 8
    /// Running best-so-far kept while the session runs (≥ finalBestN).
    var workingBestN: Int = 6
    /// Running worst-so-far (with faults) kept while the session runs
    /// (≥ finalWorstN) so representative problems aren't evicted before End.
    var workingWorstN: Int = 3
    /// Session-opener swings (useful for first-vs-last progress framing).
    var firstN: Int = 3

    // End-of-session final keep.
    var finalBestN: Int = 6
    var finalWorstN: Int = 3
    /// Keep the session's first and last swing (progress before/after).
    var keepFirstLast: Bool = true

    // Cross-session.
    /// How many recent sessions retain video clips at all. Older sessions
    /// keep JSON + report + thumbnails but lose their mp4s.
    var maxSessionsWithVideo: Int = 10

    static let standard = RetentionConfig()

    /// Field-capture mode: keep EVERY clip + every session. Range test
    /// sessions are the data flywheel — dozens of real swings with videos,
    /// ball detections and fit params are exactly the eval/training corpus,
    /// so nothing gets pruned. (~10 MB per swing clip; a 50-swing night is
    /// ~500 MB — fine for a test device, not a consumer default.)
    static let fieldCapture = RetentionConfig(
        recentWindow: 100_000, workingBestN: 100_000, workingWorstN: 100_000,
        firstN: 100_000, finalBestN: 100_000, finalWorstN: 100_000,
        keepFirstLast: true, maxSessionsWithVideo: 100_000)
}

enum RetentionPolicy {
    /// Worst-fault severity for a swing (faults are sorted strongest-first).
    private static func severity(_ s: AnnotatedSwing) -> Double {
        s.score.faults.first?.severity ?? 0
    }

    /// Is this swing readable enough to have any replay/illustration value?
    private static func readable(_ s: AnnotatedSwing) -> Bool {
        s.category != .unreadable
    }

    /// One swing number per distinct primary fault — the highest-severity
    /// example of each, so every main problem is illustrated by its clearest
    /// instance. Unreadable swings are ignored.
    private static func worstPerPrimaryFault(_ swings: [AnnotatedSwing]) -> Set<Int> {
        var best: [SwingFaultID: AnnotatedSwing] = [:]
        for s in swings where readable(s) {
            guard let fault = s.score.primaryFault else { continue }
            if let cur = best[fault], severity(cur) >= severity(s) { continue }
            best[fault] = s
        }
        return Set(best.values.map(\.swingNumber))
    }

    /// Swing numbers whose video should exist DURING the session.
    /// Bounded by construction: |recent| + |best| + |first| + |faults| + |marks|.
    static func workingKeepSet(_ swings: [AnnotatedSwing],
                               userKept: Set<Int>,
                               cfg: RetentionConfig = .standard) -> Set<Int> {
        guard let maxNum = swings.map(\.swingNumber).max() else { return userKept }
        var keep = userKept

        // Recent rolling window (includes unreadable — replay still wanted).
        for s in swings where s.swingNumber > maxNum - cfg.recentWindow {
            keep.insert(s.swingNumber)
        }
        // Running best-so-far (readable only — no point replaying noise).
        let readableSwings = swings.filter(readable)
        let byScoreDesc = readableSwings.sorted { $0.score.total > $1.score.total }
        for s in byScoreDesc.prefix(cfg.workingBestN) { keep.insert(s.swingNumber) }
        // Running worst-so-far with faults (representative problems) — kept so
        // the End-prune's worst-N is never evicted before it's chosen.
        let worstWithFaults = readableSwings
            .filter { !$0.score.faults.isEmpty }
            .sorted { $0.score.total < $1.score.total }
        for s in worstWithFaults.prefix(cfg.workingWorstN) { keep.insert(s.swingNumber) }
        // Session openers.
        for s in swings.sorted(by: { $0.swingNumber < $1.swingNumber }).prefix(cfg.firstN) {
            keep.insert(s.swingNumber)
        }
        // One representative per primary fault.
        keep.formUnion(worstPerPrimaryFault(swings))
        return keep
    }

    /// Swing numbers whose video survives the end-of-session prune (≈8-12).
    static func finalKeepSet(_ swings: [AnnotatedSwing],
                             userKept: Set<Int>,
                             cfg: RetentionConfig = .standard) -> Set<Int> {
        guard !swings.isEmpty else { return userKept }
        var keep = userKept

        let readableSwings = swings.filter(readable)
        // Best-N (the highlight material).
        for s in readableSwings.sorted(by: { $0.score.total > $1.score.total }).prefix(cfg.finalBestN) {
            keep.insert(s.swingNumber)
        }
        // Worst-N that actually have faults (representative problems, not just
        // low-detection noise).
        let withFaults = readableSwings.filter { !$0.score.faults.isEmpty }
        for s in withFaults.sorted(by: { $0.score.total < $1.score.total }).prefix(cfg.finalWorstN) {
            keep.insert(s.swingNumber)
        }
        // One per primary fault — guarantees each main problem keeps an example
        // even if best/worst-N happened to skip it.
        keep.formUnion(worstPerPrimaryFault(swings))
        // First & last swing (progress before/after).
        if cfg.keepFirstLast {
            if let first = swings.map(\.swingNumber).min() { keep.insert(first) }
            if let last = swings.map(\.swingNumber).max() { keep.insert(last) }
        }
        return keep
    }
}
