import AVFoundation
import AVKit
import SwiftUI

/// One session, two sections:
///   1. Header (swing count + duration) + Session Report card
///   2. Swing list — each row opens that swing's analysis
/// Highlights / Best / Worst / Typical-issue cards were removed; everything
/// flows through the per-swing tap and the LLM session report.
struct SessionDetailView: View {
    let session: SessionDirectory
    @Environment(FeedbackOrchestrator.self) private var feedback
    @State private var swings: [AnnotatedSwing] = []
    @State private var stats: SessionStats? = nil
    @State private var report: SessionReport? = nil
    @State private var reelURL: URL? = nil
    @State private var showReel = false
    /// 「一键成片」state. The reel is normally built at session end, but that
    /// runs inside the lifecycle's 20 s watchdog and gets silently skipped on
    /// short or thermally-throttled sessions — leaving no reel and no
    /// affordance. This is the explicit on-demand path.
    @State private var buildingReel = false
    @State private var reelFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let stats { headerCard(stats) }
                if let reelURL { reelCard(reelURL) } else { makeReelCard }
                if let stats, stats.swingCount >= 6 { trendCard(stats) }
                if let report { reportCard(report) }
                allSwingsSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .appBackground()
        .foregroundStyle(Theme.ink)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadAll() }
        .sheet(isPresented: $showReel) { reelPlayer }
    }

    /// 「一键成片」：没有精彩集时出现，点一下当场拼。需要 ≥2 段可读挥杆
    /// （拼接至少要两段素材），否则连按钮都不给，避免点了没反应。
    @ViewBuilder private var makeReelCard: some View {
        if swings.filter({ $0.category != .unreadable }).count >= 2 {
            Button {
                guard !buildingReel else { return }
                Task {
                    buildingReel = true
                    reelFailed = false
                    let url = await feedback.archive.buildHighlightReel(in: session)
                    buildingReel = false
                    if let url { reelURL = url; showReel = true } else { reelFailed = true }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "film.stack").font(.title2)
                        .foregroundStyle(Brand.primaryDeep)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("一键成片").font(.headline)
                        Text(reelFailed
                             ? "本节没有可拼接的挥杆视频"
                             : (buildingReel ? "正在拼接…" : "把本节最佳挥杆拼成合集"))
                            .font(.caption).foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer()
                    if buildingReel {
                        ProgressView()
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.title).foregroundStyle(Brand.primaryDeep)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(radius: 14)
            }
            .buttonStyle(.plain)
            .disabled(buildingReel)
        }
    }

    /// 精彩集卡片：本节最佳挥杆拼接的合集，点开播放，长按分享。
    private func reelCard(_ url: URL) -> some View {
        Button { showReel = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "film.stack").font(.title2)
                    .foregroundStyle(Brand.primaryDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("精彩集").font(.headline)
                    Text("本节最佳挥杆合集")
                        .font(.caption).foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.title).foregroundStyle(Brand.primaryDeep)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: 14)
        }
        .buttonStyle(.plain)
        .contextMenu {
            ShareLink(item: url) { Label("分享精彩集", systemImage: "square.and.arrow.up") }
        }
    }

    @ViewBuilder private var reelPlayer: some View {
        if let reelURL {
            VideoPlayer(player: AVPlayer(url: reelURL))
                .ignoresSafeArea()
                .overlay(alignment: .topTrailing) {
                    ShareLink(item: reelURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3).padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding()
                }
        }
    }

    private var title: String {
        // 按设备 locale 本地化（中文「6月14日 23:30」/英文「Jun 14 at 23:30」）。
        session.startedAt.formatted(.dateTime.month().day().hour().minute())
    }

    private func loadAll() {
        swings = feedback.archive.loadAnnotated(in: session)
        reelURL = feedback.archive.reelURL(in: session)

        let statsURL = session.root.appendingPathComponent("session_stats.json")
        let reportURL = session.root.appendingPathComponent("session_report.json")
        let statsDec = JSONDecoder(); statsDec.dateDecodingStrategy = .iso8601
        let reportDec = JSONDecoder()
        if let d = try? Data(contentsOf: statsURL) {
            stats = try? statsDec.decode(SessionStats.self, from: d)
        }
        if let d = try? Data(contentsOf: reportURL) {
            report = try? reportDec.decode(SessionReport.self, from: d)
        }
    }

    // MARK: - sub-views

    /// Minimal header: swing count + duration. Score-driven numbers
    /// (avg / range / median / sigma) are intentionally hidden — the app
    /// stopped showing scores to the user.
    private func headerCard(_ s: SessionStats) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(s.swingCount)").font(.system(size: 34, weight: .heavy))
            Text("杆").font(.callout).foregroundStyle(Theme.inkSecondary)
            Spacer()
            if let dur = s.durationMinutes {
                Text("\(Int(dur.rounded())) 分钟")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }

    /// Within-session trend, deliberately number-free (the app never shows
    /// raw scores): two normalized bars — early swings vs late swings — plus
    /// a qualitative delta line. Hidden for tiny sessions where halves are
    /// statistically meaningless.
    private func trendCard(_ s: SessionStats) -> some View {
        let lo = min(s.firstHalfAvg, s.secondHalfAvg)
        let hi = max(s.firstHalfAvg, s.secondHalfAvg, lo + 1)
        // Normalize into 0.35…1.0 so the weaker half still reads as a bar.
        func h(_ v: Double) -> CGFloat { CGFloat(0.35 + 0.65 * (v - lo) / (hi - lo)) }
        let improved = s.improvementDelta >= 0
        return VStack(alignment: .leading, spacing: 10) {
            Text("本节趋势")
                .font(.caption.bold())
                .foregroundStyle(Brand.primaryDeep)
            HStack(alignment: .bottom, spacing: 18) {
                ForEach([("Early", s.firstHalfAvg), ("Late", s.secondHalfAvg)], id: \.0) { label, v in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(label == "Late"
                                  ? AnyShapeStyle(Brand.gradient)
                                  : AnyShapeStyle(Theme.ink.opacity(0.25)))
                            .frame(width: 44, height: 64 * h(v))
                        Text(label).font(.caption2).foregroundStyle(Theme.inkSecondary)
                    }
                }
                Spacer()
                Label(improved ? "Finished stronger" : "Faded toward the end",
                      systemImage: improved ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.bold())
                    .foregroundStyle(improved ? .green : .orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }

    private func reportCard(_ r: SessionReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本节报告")
                .font(.caption.bold())
                .foregroundStyle(Brand.primaryDeep)
            Text(r.headline.isEmpty ? "—" : r.headline)
                .font(.headline)
                .foregroundStyle(Theme.ink)
            if !r.topStrength.isEmpty {
                Label(r.topStrength, systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(3)
            }
            if !r.topProblemWithFix.isEmpty {
                Label(r.topProblemWithFix, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
            NavigationLink {
                FullReportView(report: r, stats: stats)
            } label: {
                HStack(spacing: 4) {
                    Text("完整报告")
                    Image(systemName: "arrow.right")
                }
                .font(.caption.bold())
                .foregroundStyle(Brand.primary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: Brand.primaryLight.opacity(0.45), radius: 14)
    }

    /// One-row-per-swing list. Tapping a row opens that swing's analysis
    /// (ProAnalysisView). No score badges, no filter chips — replaces the
    /// old highlights row + filtered grid. Each row shows the swing
    /// number, the soft tier label, and (if any) the swing's top fault.
    private var allSwingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("每一杆")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(reviewableSwings.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
            }
            VStack(spacing: 8) {
                ForEach(reviewableSwings, id: \.id) { sw in
                    NavigationLink {
                        ArchiveProAnalysisRoute(swing: sw, session: session)
                            .environment(feedback)
                    } label: {
                        swingRow(sw)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Only swings whose clip actually survived retention (video on disk).
    /// No point listing a swing whose video we deliberately didn't keep — the
    /// row would open to an empty player. Analysis JSON for every swing is
    /// still on disk; it just isn't surfaced as a reviewable row.
    private var reviewableSwings: [AnnotatedSwing] {
        swings.filter { sw in
            let u = session.root
                .appendingPathComponent("video")
                .appendingPathComponent(String(format: "swing_%03d.mp4", sw.swingNumber))
            return FileManager.default.fileExists(atPath: u.path)
        }
    }

    private func swingRow(_ sw: AnnotatedSwing) -> some View {
        HStack(spacing: 14) {
            // Numbered chip, brand-coloured
            Text("\(sw.swingNumber)")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Brand.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text("第 \(sw.swingNumber) 杆")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.ink.opacity(0.35))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 12)
    }
}

/// Async wrapper that opens an archived swing in the same ProAnalysisView used
/// by Upload mode. Before constructing the SwingReport we load the on-disk mp4's
/// actual oriented dimensions from `preferredTransform` + `naturalSize`. Without
/// this the report defaults to 1080×1920, and any source with a different
/// aspect (DJI Pocket, GoPro, etc.) renders the skeleton offset from the body
/// because PoseOverlay scales normalized keypoints against the wrong frame.
private struct ArchiveProAnalysisRoute: View {
    let swing: AnnotatedSwing
    let session: SessionDirectory
    @Environment(FeedbackOrchestrator.self) private var feedback
    @State private var report: SwingReport?
    @State private var failedToBuild: Bool = false

    var body: some View {
        Group {
            if let report {
                ProAnalysisView(report: report,
                                compareSession: session,
                                selfSwingNumber: swing.swingNumber)
                    .environment(feedback)
            } else if failedToBuild {
                SwingDetailView(swing: swing, session: session)
                    .environment(feedback)
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().tint(.white).scaleEffect(1.2)
                        Text("正在分析这一杆…")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("解码姿态 + 重算指标中")
                            .font(.caption2).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let videoSize = await Self.orientedVideoSize(for: swing, in: session)
        // Build the SwingReport on a detached background task so the UI
        // thread doesn't stall on pose-JSON decode + metrics computation
        // when the user taps into Swing Analysis. Without this the page
        // appears frozen for a beat while the report is constructed.
        let archive = feedback.archive
        let swingCopy = swing
        let sessionCopy = session
        let built = await Task.detached(priority: .userInitiated) { () -> SwingReport? in
            archive.loadSwingReport(annotated: swingCopy,
                                    in: sessionCopy,
                                    videoSize: videoSize)
        }.value
        if let r = built {
            await MainActor.run { self.report = r }
        } else {
            await MainActor.run { self.failedToBuild = true }
        }
    }

    private static func orientedVideoSize(for swing: AnnotatedSwing,
                                          in session: SessionDirectory) async -> CGSize {
        let fallback = CGSize(width: 1080, height: 1920)
        guard let rel = swing.videoPath else { return fallback }
        let url = session.root.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first
        else { return fallback }
        let natural = (try? await track.load(.naturalSize)) ?? fallback
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        // Apply the track's preferredTransform to the natural size — the
        // |result| has the dimensions of the displayed frame. Works for
        // identity (already-oriented natural size), π/2 rotation
        // (landscape sensor → portrait display), and the mirrored variants.
        let oriented = natural.applying(transform)
        let w = max(1, abs(oriented.width))
        let h = max(1, abs(oriented.height))
        let result = CGSize(width: w, height: h)
        print(String(format: "[ArchiveRoute] %@ natural=%.0fx%.0f " +
                     "transform=(a=%.2f,b=%.2f,c=%.2f,d=%.2f) → oriented=%.0fx%.0f",
                     rel, natural.width, natural.height,
                     transform.a, transform.b, transform.c, transform.d,
                     result.width, result.height))
        return result
    }
}

/// Bare full-screen report viewer — used when tapping "Full report →".
/// Reuses the layout we'd otherwise show via SessionReportView, but it pulls
/// data from a stored report (not from lifecycle state).
private struct FullReportView: View {
    let report: SessionReport
    let stats: SessionStats?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !report.headline.isEmpty {
                    Text(report.headline)
                        .font(.title2.bold())
                        .padding(.bottom, 4)
                }
                // Score-summary row intentionally omitted — scores aren't
                // surfaced anywhere in the app anymore.
                row(String(localized: "做得好的"), report.topStrength, .green, "checkmark.seal.fill")
                row(String(localized: "要改的"), report.topProblemWithFix, .orange, "exclamationmark.triangle.fill")
                row(String(localized: "进展"), report.sessionProgress, Brand.primaryDeep, "arrow.up.right")
                row(String(localized: "下节目标"), report.nextSessionGoal, Brand.primary, "target")
            }
            .padding(16)
        }
        .appBackground()
        .foregroundStyle(Theme.ink)
        .navigationTitle("报告")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ text: String, _ color: Color, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.bold()).foregroundStyle(color)
                Text(text.isEmpty ? "—" : text).font(.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 10)
    }
}
