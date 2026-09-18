import AVKit
import Photos
import SwiftUI

/// Full detail of one archived swing: video (if available), 8-event scrub,
/// score breakdown, strengths/problems list, coach replay, per-event metrics.
struct SwingDetailView: View {
    let swing: AnnotatedSwing
    let session: SessionDirectory
    @Environment(FeedbackOrchestrator.self) private var feedback
    @State private var player: AVPlayer?
    @State private var loopObserver: Any?
    @State private var expandedPerEvent: Bool = false
    @State private var saveStatus: SaveStatus = .idle

    enum SaveStatus: Equatable { case idle, saving, saved, failed(String) }

    private var videoURL: URL? {
        guard let rel = swing.videoPath else { return nil }
        return session.root.appendingPathComponent(rel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerBadge
                videoSection
                scoreSection
                strengthsList
                problemsList
                coachLine
                perEventTable
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        // 这是自带黑底白字的深色视频屏：强制深色，内部玻璃卡才会渲染成深色磨砂
        // （否则在浅色 app 里玻璃变浅、白字看不清）。
        .preferredColorScheme(.dark)
        .navigationTitle("第 \(swing.swingNumber) 杆")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { setupPlayer() }
        .onDisappear { teardownPlayer() }
    }

    private var headerBadge: some View {
        HStack {
            Text(categoryLabel.uppercased())
                .font(.caption.bold())
                .foregroundStyle(categoryColor)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(categoryColor.opacity(0.18))
                .clipShape(Capsule())
            Spacer()
            Text(timestamp)
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder
    private var videoSection: some View {
        if let url = videoURL, FileManager.default.fileExists(atPath: url.path) {
            VStack(alignment: .leading, spacing: 6) {
                VideoPlayer(player: player)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                downloadRow(url: url)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "video.slash")
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.35))
                Text("这一杆没有保存视频")
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity).frame(height: 200)
            .background(.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func downloadRow(url: URL) -> some View {
        HStack(spacing: 8) {
            Spacer()
            switch saveStatus {
            case .idle:
                Button { Task { await save(url: url) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        Text("存到相册").font(.caption.bold())
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white.opacity(0.1))
                    .clipShape(Capsule())
                }
            case .saving:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("保存中…").font(.caption)
                }
            case .saved:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("已存到相册").font(.caption).foregroundStyle(.green)
                }
            case .failed(let msg):
                Text("保存失败：\(msg)").font(.caption).foregroundStyle(.orange)
                Button("重试") { Task { await save(url: url) } }
                    .font(.caption.bold())
            }
        }
    }

    private func save(url: URL) async {
        saveStatus = .saving
        do {
            let status = await requestPhotoAddAuth()
            guard status == .authorized || status == .limited else {
                saveStatus = .failed("Photos access denied")
                return
            }
            try await writeVideo(to: PHPhotoLibrary.shared(), from: url)
            saveStatus = .saved
        } catch {
            saveStatus = .failed(error.localizedDescription)
        }
    }

    private func requestPhotoAddAuth() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current != .notDetermined { return current }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                cont.resume(returning: status)
            }
        }
    }

    private func writeVideo(to library: PHPhotoLibrary, from url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            library.performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { success, error in
                if success { cont.resume() }
                else { cont.resume(throwing: error ?? NSError(domain: "SaveVideo", code: -1)) }
            }
        }
    }

    private var scoreSection: some View {
        HStack(alignment: .top, spacing: 18) {
            // Soft tier + summary only. No numeric scores or sub-bars.
            VStack(spacing: 4) {
                Text(swing.score.tier.label)
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(scoreColor(swing.score.total))
                    .multilineTextAlignment(.center)
                Text(swing.score.summaryShort)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(categoryLabel.uppercased())
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.top, 4)
            }
            Spacer()
        }
        .padding(14)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func subScoreBar(_ label: String, _ v: Double, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.7))
                .frame(width: 90, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.1)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geo.size.width * max(0, min(1, v)), height: 6)
                }
            }.frame(height: 6)
            Text(String(format: "%.2f", v)).font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.7)).frame(width: 40, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var strengthsList: some View {
        if !swing.strengths.isEmpty {
            section(String(localized: "优势"), color: .green) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(swing.strengths, id: \.id) { s in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(.green)
                            Text(strengthLine(s)).font(.callout)
                        }
                    }
                }
            }
        }
    }

    private func strengthLine(_ s: SwingStrength) -> String {
        if let v = s.evidenceValue, let u = s.evidenceUnit {
            return "\(s.id.label) — \(Int(v.rounded())) \(u)"
        }
        return s.id.label
    }

    @ViewBuilder
    private var problemsList: some View {
        if !swing.score.faults.isEmpty {
            section(String(localized: "问题"), color: .orange) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(swing.score.faults, id: \.id) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(.orange)
                                Text(faultLine(f)).font(.callout)
                            }
                            Text(f.id.fix).font(.caption2)
                                .foregroundStyle(.white.opacity(0.65))
                                .padding(.leading, 12)
                        }
                    }
                }
            }
        }
    }

    private func faultLine(_ f: SwingFault) -> String {
        if let v = f.evidenceValue, let u = f.evidenceUnit {
            return "\(f.id.label) — \(Int(v.rounded())) \(u) (sev \(String(format: "%.1f", f.severity)))"
        }
        return "\(f.id.label) (sev \(String(format: "%.1f", f.severity)))"
    }

    @ViewBuilder
    private var coachLine: some View {
        if let spoken = swing.spokenFeedback, !spoken.isEmpty {
            section(String(localized: "教练点评"), color: Brand.primary) {
                Text("“\(spoken)”").font(.callout).italic()
            }
        }
    }

    /// Per-event metrics table (Upload-mode parity). Shows shoulder/hip/x-factor/
    /// spine/elbow/knee at each of the 8 events. Joint values are degrees;
    /// blanks mean confidence was too low at that event.
    @ViewBuilder
    private var perEventTable: some View {
        if !swing.perEvent.isEmpty {
            section(String(localized: "各事件指标"), color: .blue) {
                VStack(alignment: .leading, spacing: 0) {
                    // Header row
                    perEventHeaderRow
                    Divider().background(.white.opacity(0.15)).padding(.vertical, 2)
                    ForEach(swing.perEvent, id: \.event) { e in
                        perEventRow(e)
                    }
                }
            }
        }
    }

    private var perEventHeaderRow: some View {
        HStack(spacing: 6) {
            Text("event").frame(width: 64, alignment: .leading)
            Text("shoulder").frame(width: 50, alignment: .trailing)
            Text("hip").frame(width: 38, alignment: .trailing)
            Text("X").frame(width: 36, alignment: .trailing)
            Text("spine").frame(width: 44, alignment: .trailing)
            Text("L-el").frame(width: 38, alignment: .trailing)
            Text("L-kn").frame(width: 38, alignment: .trailing)
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.white.opacity(0.55))
    }

    private func perEventRow(_ e: PerEventMetrics) -> some View {
        HStack(spacing: 6) {
            Text(shortEventName(e.event)).frame(width: 64, alignment: .leading)
                .foregroundStyle(.white)
            cell(e.shoulderTilt, w: 50)
            cell(e.hipTilt, w: 38)
            cell(e.xFactor, w: 36)
            cell(e.spineTilt, w: 44)
            cell(e.leadElbow, w: 38)
            cell(e.leadKnee, w: 38)
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private func cell(_ value: Double?, w: CGFloat) -> some View {
        Group {
            if let v = value {
                Text(String(format: "%.0f°", v))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Text("—").foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: w, alignment: .trailing)
    }

    private func shortEventName(_ display: String) -> String {
        switch display {
        case "Address":           return "Addr"
        case "Toe-up":            return "Toe"
        case "Mid-backswing":     return "MidBs"
        case "Top":               return "Top"
        case "Mid-downswing":     return "MidDs"
        case "Impact":            return "Imp"
        case "Mid-follow-through": return "MidFl"
        case "Finish":            return "Fin"
        default:                  return display
        }
    }

    private func section<Content: View>(_ title: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold()).foregroundStyle(color)
            content()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - player

    private func setupPlayer() {
        guard let url = videoURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { _ in
            p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            p.play()
        }
        player = p
        p.play()
    }

    private func teardownPlayer() {
        player?.pause()
        if let obs = loopObserver { NotificationCenter.default.removeObserver(obs) }
        loopObserver = nil
        player = nil
    }

    // MARK: - bits

    private var categoryLabel: String {
        switch swing.category {
        case .clean:      return String(localized: "干净")
        case .promising:  return String(localized: "有潜力")
        case .needsWork:  return String(localized: "需打磨")
        case .problem:    return String(localized: "有问题")
        case .unreadable: return String(localized: "难判读")
        }
    }
    private var categoryColor: Color {
        switch swing.category {
        case .clean:      return .green
        case .promising:  return .yellow
        case .needsWork:  return .orange
        case .problem:    return .red
        case .unreadable: return .gray
        }
    }
    private var timestamp: String {
        let df = DateFormatter(); df.dateFormat = "MMM d, h:mm:ss a"
        return df.string(from: swing.timestamp)
    }
    private func scoreColor(_ s: Int) -> Color {
        if s >= 80 { return .green }
        if s >= 65 { return .yellow }
        if s >= 50 { return .orange }
        return .red
    }
}
