import Foundation
import Observation

/// In-app log ring buffer. Anything written via `dbg("...")` shows up both
/// in the Xcode console (via print) AND in the on-screen debug HUD, so we
/// can diagnose live-tap issues without needing the device tethered.
@Observable
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()

    /// Most recent entries, newest last. Capped at `maxEntries`.
    private(set) var entries: [Entry] = []
    /// Toggles whether the overlay is visible. Defaults on for now.
    var visible: Bool = true

    private let lock = NSLock()
    private let maxEntries = 80

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let time: Date
        let tag: String
        let message: String
        let level: Level
    }

    enum Level: Sendable {
        case info, warn, error
    }

    func log(_ message: String, tag: String = "log", level: Level = .info) {
        let entry = Entry(time: Date(), tag: tag, message: message, level: level)
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()
        // Always also print so the Xcode console keeps its existing behaviour.
        print("[\(tag)] \(message)")
    }

    func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}

/// Top-level convenience so call sites read like `dbg(.info, tag: "tts", "started")`.
func dbg(_ level: DebugLog.Level = .info, tag: String, _ message: String) {
    DebugLog.shared.log(message, tag: tag, level: level)
}
