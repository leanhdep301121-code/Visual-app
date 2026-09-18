import SwiftUI

/// Translucent bottom panel showing the latest DebugLog entries.
/// Sticky-to-bottom; expands on tap. Only meant for development / on-device
/// diagnostics where the Xcode console is unavailable.
struct DebugLogOverlay: View {
    @State private var log = DebugLog.shared
    @State private var expanded: Bool = false

    var body: some View {
        if log.visible {
            VStack(spacing: 0) {
                Spacer().frame(height: 100)   // sit below the topBar; never cover bottom controls
                content
                    .padding(.horizontal, 6)
                Spacer()
            }
            .allowsHitTesting(true)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(log.entries) { e in
                            row(e).id(e.id)
                        }
                    }
                    .padding(6)
                }
                .frame(height: expanded ? 240 : 90)
                .onChange(of: log.entries.count) { _, _ in
                    if let last = log.entries.last {
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(.black.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").font(.caption)
            Text("debug log (\(log.entries.count))").font(.caption.bold())
            Spacer()
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.up").font(.caption)
            }
            Button { log.clear() } label: {
                Image(systemName: "trash").font(.caption)
            }
            Button { log.visible = false } label: {
                Image(systemName: "xmark").font(.caption)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(.white)
        .background(.black.opacity(0.5))
    }

    private func row(_ e: DebugLog.Entry) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(timeStr(e.time))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
            Text(e.tag)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(tagColor(e.tag))
            Text(e.message)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(color(e.level))
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
    }

    private func timeStr(_ d: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss.SSS"
        return df.string(from: d)
    }

    private func color(_ l: DebugLog.Level) -> Color {
        switch l {
        case .info: return .white
        case .warn: return .yellow
        case .error: return .red
        }
    }
    private func tagColor(_ tag: String) -> Color {
        switch tag {
        case "tts":   return .cyan
        case "coach": return .green
        case "el":    return .pink
        case "cam":   return .orange
        default:      return .white.opacity(0.7)
        }
    }
}
