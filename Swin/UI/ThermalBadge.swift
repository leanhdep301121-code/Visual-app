import SwiftUI

@Observable
final class ThermalMonitor: @unchecked Sendable {
    private(set) var state: ProcessInfo.ThermalState = .nominal
    private var observer: NSObjectProtocol?

    init() {
        state = ProcessInfo.processInfo.thermalState
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.state = ProcessInfo.processInfo.thermalState
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

struct ThermalBadge: View {
    let state: ProcessInfo.ThermalState

    var body: some View {
        if state == .nominal { EmptyView() }
        else {
            HStack(spacing: 4) {
                Image(systemName: "thermometer.high").font(.caption)
                Text(label).font(.caption.bold())
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(color)
            .clipShape(Capsule())
        }
    }

    private var label: String {
        switch state {
        case .nominal: return String(localized: "正常")
        case .fair: return String(localized: "微热")
        case .serious: return String(localized: "偏热")
        case .critical: return String(localized: "过热")
        @unknown default: return "?"
        }
    }

    private var color: Color {
        switch state {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }
}
