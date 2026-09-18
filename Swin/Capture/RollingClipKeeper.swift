import AVFoundation
import CoreMedia
import Foundation

/// Dynamic video saving: record continuously into short rolling chunks but only
/// PERSIST the ones worth keeping — otherwise an hour of capture fills storage
/// (1080p30 ≈ 90 MB/min). Unkept chunks are deleted as they age out of the ring.
///
/// Keep signals come from above (`CaptureController`): a high `SwingScore`
/// (system, currently hidden) or an explicit user gesture/voice "save this one".
/// On `keepRecent()` we retain the chunk the swing landed in plus the previous
/// one (a swing can straddle a boundary).
///
/// One keeper per recorded stream — in multi-angle the wide + tele each get one,
/// so a kept swing persists both angles.
final class RollingClipKeeper: @unchecked Sendable {
    private let dir: URL
    private let keptDir: URL
    private let sensorSize: CGSize
    private let isFront: Bool
    private let chunkSeconds: TimeInterval
    private let ringCount: Int           // unkept chunks retained while waiting for a keep decision

    private let lock = NSLock()
    private var rolling = false
    private var current: VideoRecorder?
    private var currentURL: URL?
    private var currentStart: CFTimeInterval = 0
    private var ring: [URL] = []          // finished, not-yet-kept chunk files (oldest first)
    private var pendingKeepCurrent = false
    private var seq = 0
    private(set) var keptClips: [URL] = []

    init(label: String, sensorSize: CGSize, isFront: Bool,
         chunkSeconds: TimeInterval = 4, ringCount: Int = 2) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.dir = docs.appendingPathComponent("rolling/\(label)", isDirectory: true)
        self.keptDir = docs.appendingPathComponent("kept/\(label)", isDirectory: true)
        self.sensorSize = sensorSize
        self.isFront = isFront
        self.chunkSeconds = chunkSeconds
        self.ringCount = ringCount
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: keptDir, withIntermediateDirectories: true)
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !rolling else { return }
        rolling = true
        openChunkLocked()
    }

    /// Feed a video frame (called on the capture sample queue).
    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        guard rolling else { lock.unlock(); return }
        let rec = current
        let elapsed = CACurrentMediaTime() - currentStart
        lock.unlock()
        rec?.appendVideo(sampleBuffer)
        if elapsed >= chunkSeconds { rotate(keepClosing: false) }
    }

    /// Persist the footage around the swing that just finished: the previous
    /// chunk (already closed) + the current one (force-closed now).
    func keepRecent() {
        lock.lock()
        if let prev = ring.popLast() { moveToKeptLocked(prev) }
        pendingKeepCurrent = true
        lock.unlock()
        rotate(keepClosing: true)
    }

    func stop() {
        lock.lock(); rolling = false; let rec = current, url = currentURL
        current = nil; currentURL = nil
        let leftovers = ring; ring.removeAll()
        lock.unlock()
        Task { if let rec { _ = await rec.finish() } }
        for u in leftovers { try? FileManager.default.removeItem(at: u) }
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - chunk rotation

    private func rotate(keepClosing: Bool) {
        lock.lock()
        guard rolling, let old = current, let oldURL = currentURL else { lock.unlock(); return }
        let keep = pendingKeepCurrent || keepClosing
        pendingKeepCurrent = false
        openChunkLocked()
        lock.unlock()

        Task { [weak self] in
            _ = await old.finish()
            guard let self else { return }
            self.lock.lock()
            if keep {
                self.moveToKeptLocked(oldURL)
            } else {
                self.ring.append(oldURL)
                while self.ring.count > self.ringCount {
                    let drop = self.ring.removeFirst()
                    try? FileManager.default.removeItem(at: drop)
                }
            }
            self.lock.unlock()
        }
    }

    private func openChunkLocked() {
        seq += 1
        let url = dir.appendingPathComponent(String(format: "chunk_%05d.mp4", seq))
        guard let rec = try? VideoRecorder(outputURL: url, sensorSize: sensorSize, isFrontCamera: isFront) else { return }
        rec.start()
        current = rec
        currentURL = url
        currentStart = CACurrentMediaTime()
    }

    private func moveToKeptLocked(_ url: URL) {
        let dest = keptDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            keptClips.append(dest)
            // Every kept stream goes to the system Photos album — in multi-angle
            // that means BOTH the wide AND the tele clip land in 相册.
            PhotoSaver.saveVideo(dest)
        } catch {
            // file may not be flushed yet on a force-keep; ignore — best effort
        }
    }
}
