import Foundation
import Observation
import UIKit

/// Power / thermal benchmark runner. Logs battery % and thermal state at a
/// fixed cadence while the app holds a configured mode (full pipeline vs.
/// camera-only vs. idle). After the run, writes a JSON log to Documents/
/// for later inspection.
///
/// Usage: Bench tab → pick mode → pick duration → tap Start. Keep the app
/// foreground for the whole run (screen always-on, don't switch apps).
@Observable
final class PowerBench: @unchecked Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case full      = "full"      // camera + YOLO + PoseTCN sliding-window
        case cameraOnly = "camera"   // camera frames captured, no YOLO inference
        case idle      = "idle"      // camera off, just screen on
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .full:       return "Full pipeline (YOLO + PoseTCN)"
            case .cameraOnly: return "Camera only (no YOLO)"
            case .idle:       return "Idle (no camera)"
            }
        }
    }

    enum State: Equatable { case idle, running, finished, aborted }

    private(set) var state: State = .idle
    private(set) var mode: Mode = .full
    private(set) var startedAt: Date?
    private(set) var endsAt: Date?
    private(set) var samples: [Sample] = []
    private(set) var lastLogURL: URL?

    private var sampleTimer: Timer?

    struct Sample: Codable, Sendable {
        let elapsedSeconds: Double
        let batteryLevel: Float        // 0…1 or -1 if monitoring unavailable
        let batteryState: String       // "unknown", "unplugged", "charging", "full"
        let thermalState: String       // "nominal", "fair", "serious", "critical"
    }

    struct Log: Codable, Sendable {
        let mode: Mode
        let plannedDurationSeconds: Double
        let startedAt: Date
        let endedAt: Date
        let device: String
        let osVersion: String
        let samples: [Sample]

        var deltaPct: Float {
            guard let first = samples.first,
                  let last  = samples.last,
                  first.batteryLevel >= 0, last.batteryLevel >= 0 else { return 0 }
            return (first.batteryLevel - last.batteryLevel) * 100
        }
        var elapsedMin: Double {
            (samples.last?.elapsedSeconds ?? 0) / 60.0
        }
        var dropPerHour: Float {
            elapsedMin > 0 ? Float(deltaPct) / Float(elapsedMin / 60.0) : 0
        }
    }

    func start(mode: Mode, durationSeconds: Double, sampleEverySeconds: Double = 15) {
        guard state != .running else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        self.mode = mode
        let now = Date()
        startedAt = now
        endsAt = now.addingTimeInterval(durationSeconds)
        samples = []
        state = .running
        UIApplication.shared.isIdleTimerDisabled = true
        recordSample(force: true)
        sampleTimer = Timer.scheduledTimer(withTimeInterval: sampleEverySeconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordSample(force: false)
            if let end = self.endsAt, Date() >= end {
                self.finish()
            }
        }
    }

    func abort() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        state = .aborted
    }

    private func finish() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        recordSample(force: true)
        state = .finished
        persistLog()
    }

    private func recordSample(force: Bool) {
        guard let started = startedAt else { return }
        let elapsed = Date().timeIntervalSince(started)
        let level = UIDevice.current.batteryLevel        // -1 if disabled
        let bstate = batteryStateName(UIDevice.current.batteryState)
        let tstate = thermalStateName(ProcessInfo.processInfo.thermalState)
        samples.append(Sample(
            elapsedSeconds: elapsed,
            batteryLevel: level,
            batteryState: bstate,
            thermalState: tstate
        ))
        if force { print("[PowerBench] sample @ \(Int(elapsed))s: battery=\(Int(level * 100))% thermal=\(tstate)") }
    }

    private func persistLog() {
        guard let started = startedAt else { return }
        let planned = (endsAt?.timeIntervalSince(started)) ?? 0
        let log = Log(
            mode: mode,
            plannedDurationSeconds: planned,
            startedAt: started,
            endedAt: Date(),
            device: UIDevice.current.model + " · " + (modelIdentifier() ?? "?"),
            osVersion: UIDevice.current.systemVersion,
            samples: samples
        )
        do {
            let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let dir = docs.appendingPathComponent("PowerBench", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fname = "bench_\(mode.rawValue)_\(Int(started.timeIntervalSince1970)).json"
            let url = dir.appendingPathComponent(fname)
            let data = try JSONEncoder.iso.encode(log)
            try data.write(to: url)
            lastLogURL = url
            print("[PowerBench] log → \(url.path)")
            print("[PowerBench] result: mode=\(mode.rawValue) elapsed=\(String(format: "%.1f", log.elapsedMin))min "
                  + "Δ=\(String(format: "%.1f", log.deltaPct))% rate=\(String(format: "%.1f", log.dropPerHour))%/hr")
        } catch {
            print("[PowerBench] persist failed: \(error.localizedDescription)")
        }
    }

    private func batteryStateName(_ s: UIDevice.BatteryState) -> String {
        switch s {
        case .unknown:   return "unknown"
        case .unplugged: return "unplugged"
        case .charging:  return "charging"
        case .full:      return "full"
        @unknown default: return "unknown"
        }
    }
    private func thermalStateName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
    private func modelIdentifier() -> String? {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = sysinfo.machine
        let size = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: machine) { ptr -> String? in
            ptr.withMemoryRebound(to: CChar.self, capacity: size) {
                String(validatingUTF8: $0)
            }
        }
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
