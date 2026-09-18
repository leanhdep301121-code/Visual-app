import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct UploadView: View {
    @Environment(FeedbackOrchestrator.self) private var feedback

    @State private var analyzer: VideoAnalyzer = {
        let pose: PoseService = (try? YoloPoseService()) ?? VisionPoseService()
        let detector: any EventDetector = (try? PoseTCNEventDetector()) ?? HeuristicEventDetector()
        return VideoAnalyzer(poseService: pose, eventDetector: detector)
    }()

    @State private var pickerItem: PhotosPickerItem?
    @State private var stagedURL: URL?
    @State private var showResult = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 16) {
                header
                Spacer()
                statusSection
                Spacer()
                pickerButton
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadAndAnalyze(item: item) }
        }
        .onChange(of: analyzer.report?.id) { _, id in
            guard id != nil, analyzer.report != nil else { return }
            showResult = true
        }
        .fullScreenCover(isPresented: $showResult, onDismiss: resetForNextUpload) {
            if let report = analyzer.report, report.recordingURL != nil {
                ProAnalysisView(report: report)
                    .environment(feedback)
            }
        }
    }

    /// Wipes the picker selection + analyzer state after the user closes
    /// the analysis sheet. Two reasons:
    ///   - `PhotosPickerItem` equality means picking the same video again
    ///     wouldn't fire `onChange` if we left the old selection around.
    ///   - Returning to the Upload tab should show the clean empty state,
    ///     not a stale "Analysis complete / View result" frozen card.
    private func resetForNextUpload() {
        pickerItem = nil
        stagedURL = nil
        analyzer.reset()
    }

    // MARK: - sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("上传挥杆")
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.ink)
            Text("选一段竖屏的高尔夫挥杆视频来分析")
                .font(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 30)
    }

    @ViewBuilder
    private var statusSection: some View {
        switch analyzer.status {
        case .idle:
            placeholder(String(localized: "点下方选一段视频"))
        case .extracting(let progress):
            VStack(spacing: 14) {
                ProgressView(value: progress)
                    .tint(Brand.primary)
                    .frame(maxWidth: 280)
                Text("提取姿态中 · \(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.ink.opacity(0.85))
            }
        case .analyzing:
            VStack(spacing: 10) {
                ProgressView().tint(Brand.primary)
                Text("检测挥杆事件 + 指标中…")
                    .font(.caption)
                    .foregroundStyle(Theme.ink.opacity(0.85))
            }
        case .done:
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Brand.primary)
                Text("分析完成")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Button("查看结果") { showResult = true }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .glassCard(tint: Brand.primary, radius: 22)
            }
        case .failed(let msg):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(Theme.ink.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.4))
                    .frame(width: 120, height: 120)
                Image(systemName: "video.badge.plus")
                    .font(.system(size: 52))
                    .foregroundStyle(Brand.primary)
            }
            .glassCard(radius: 60)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    private var pickerButton: some View {
        PhotosPicker(
            selection: $pickerItem,
            matching: .videos,
            photoLibrary: .shared()
        ) {
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                Text("选择视频")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(.white)
            .glassCard(tint: Brand.primary, radius: 14)
            .shadow(color: Brand.primary.opacity(0.25), radius: 10, y: 4)
        }
        .disabled({
            if case .extracting = analyzer.status { return true }
            if case .analyzing  = analyzer.status { return true }
            return false
        }())
    }

    private func loadAndAnalyze(item: PhotosPickerItem) async {
        guard let movie = try? await item.loadTransferable(type: TransferableMovie.self) else {
            return
        }
        stagedURL = movie.url
        // 不再问机位/惯用手：机位默认目标线后方，惯用手交给自动检测（nil）。
        await analyzer.analyze(url: movie.url, viewpoint: .downTheLine, handedness: nil,
                               isImported: true)
    }
}

private struct TransferableMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + ext)
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.copyItem(at: received.file, to: tmp)
            return Self(url: tmp)
        }
    }
}
