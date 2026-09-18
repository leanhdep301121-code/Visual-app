import SwiftUI

/// The Practice home (tab 1 of the 4-tab IA): a big "Start new session"
/// card (opens the camera as a full-screen cover, which runs
/// session-onboarding then live capture) + the most recent sessions.
/// The FULL history lives in the History tab (`HistoryView` below).
struct PracticeHomeView: View {
    @Environment(FeedbackOrchestrator.self) private var feedback
    @Environment(CameraService.self) private var camera
    @State private var sessions: [SessionDirectory] = []
    @State private var showSession = false
    /// Hero photo, loaded once from the bundle by path.
    static let heroImage: UIImage = {
        Bundle.main.path(forResource: "hero_swing", ofType: "jpg")
            .flatMap { UIImage(contentsOfFile: $0) } ?? UIImage()
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    captureHero
                    uploadEntry
                    if sessions.isEmpty {
                        practiceEmptyState
                    } else {
                        HStack {
                            Text("最近")
                                .font(.system(size: 13, weight: .bold)).tracking(0.6)
                                .foregroundStyle(Theme.textMute)
                            Spacer()
                            allHistoryLink
                        }
                        .padding(.leading, 6).padding(.trailing, 2).padding(.top, 8)
                        recentStrip
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .appBackground()
            .foregroundStyle(Theme.ink)
            .navigationTitle("练习")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { reload() }
        }
        // The camera lives here as a cover: presenting it runs onboarding →
        // live capture → report, then dismisses back here. History refreshes
        // on dismiss so the just-finished session shows up immediately.
        .fullScreenCover(isPresented: $showSession, onDismiss: reload) {
            RecordView()
                .environment(feedback)
                .environment(camera)
        }
    }

    /// Top card — the single entry point into a live session. 玻璃蓝渐变 hero +
    /// 圆形图标徽章 + 圆形箭头 + 顶部镜面高光 + 蓝色辉光投影。
    /// The app's centrepiece — must be the visual centre AND sit comfortably in
    /// the light-glass language AND read instantly as "shoot your swing".
    /// A light frosted card (on-style, comfortable) faintly accent-tinted so it
    /// clearly outranks the upload row, anchored by a bold RED record button
    /// with a warm glow (the universal "shoot" cue + the focal pop that makes it
    /// the centre) and a "● 实时挥杆" live tag.
    private var captureHero: some View {
        Button { showSession = true } label: {
            ZStack(alignment: .bottomLeading) {
                // 真实高尔夫场景铺进玻璃卡——一眼是"拍你的挥杆"。
                // 直接从 bundle 路径读（散图 Asset Catalog / UIImage(named:) 都不认）。
                Image(uiImage: Self.heroImage)
                    .resizable().scaledToFill()
                // 上淡下暗的可读性 scrim（保住文字），+ 一层轻微冷色调统一到玻璃语言。
                LinearGradient(
                    colors: [.black.opacity(0.18), .clear, .black.opacity(0.10), .black.opacity(0.62)],
                    startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Circle().fill(recordRed).frame(width: 6, height: 6)
                        Text("实时挥杆").font(.system(size: 11, weight: .bold)).tracking(1.4)
                            .foregroundStyle(.white.opacity(0.95))
                    }
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    Spacer()
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("开始新一节")
                                .font(Theme.display(28, .bold)).foregroundStyle(.white)
                            Text("对准挥杆，点一下就开拍")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
                        Spacer(minLength: 8)
                        recordButton
                    }
                }
                .padding(22)
            }
            .frame(height: 430)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.30), lineWidth: 1))
            .shadow(color: Theme.shadowSoft.opacity(0.30), radius: 22, y: 12)
        }
        .buttonStyle(.pressable)
    }

    private var recordRed: Color { Color(.sRGB, red: 1, green: 0.27, blue: 0.23) }

    /// Record button — white ring + red core with a glow. Reads on the photo;
    /// the universal "shoot" cue + focal point of the home.
    private var recordButton: some View {
        ZStack {
            Circle().fill(recordRed.opacity(0.20)).frame(width: 68, height: 68).blur(radius: 7)
            Circle().strokeBorder(.white.opacity(0.95), lineWidth: 3.5).frame(width: 60, height: 60)
            Circle().fill(recordRed).frame(width: 44, height: 44)
                .shadow(color: recordRed.opacity(0.55), radius: 9, y: 2)
        }
    }

    /// 上传已有视频（backup，次要入口，从练习页进；不占 tab）。
    private var uploadEntry: some View {
        NavigationLink {
            UploadView().environment(feedback)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("上传已有视频")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("分析一段你已经录好的挥杆")
                        .font(.caption2).foregroundStyle(Theme.textDim)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold)).foregroundStyle(Theme.ink.opacity(0.3))
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: 16)
        }
        .buttonStyle(.plain)
    }

    /// 全部历史入口（内联小链接，放在「最近」标题右侧）。
    private var allHistoryLink: some View {
        NavigationLink {
            HistoryView().environment(feedback)
        } label: {
            HStack(spacing: 2) {
                Text("全部").font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
    }

    /// Recent — a compact horizontal strip of mini cards (was 3 tall cards that
    /// ate 70% of the home). Keeps the live-capture hero the visual centre.
    private var recentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(sessions.prefix(8), id: \.id) { s in
                    NavigationLink {
                        SessionDetailView(session: s).environment(feedback)
                    } label: {
                        recentMini(s)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 2)
        }
    }

    private func recentMini(_ s: SessionDirectory) -> some View {
        let live = s.endedAt == nil
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(live ? Theme.accent : Theme.good).frame(width: 6, height: 6)
                Text(dayLabel(s.startedAt))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            Text(timeLabel(s.startedAt))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textMute)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(s.swingCount)")
                    .font(Theme.display(23, .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                Text("杆").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMute)
            }
        }
        .padding(13)
        .frame(width: 120, height: 104, alignment: .leading)
        .glassCard(radius: 18)
    }

    private var practiceEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "figure.golf")
                .font(.system(size: 56))
                .foregroundStyle(Theme.ink.opacity(0.3))
            Text("还没有练习记录").font(.title3.bold())
                .foregroundStyle(Theme.ink)
            Text("开始一节练习 — 每一节都会存在这里。")
                .font(.caption).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private func reload() {
        sessions = feedback.archive.loadAllSessions()
    }
}

/// The History tab — the full session archive, sectioned by recency.
struct HistoryView: View {
    @Environment(FeedbackOrchestrator.self) private var feedback
    @State private var sessions: [SessionDirectory] = []

    var body: some View {
        // 被「练习」页 push 进来，用所在 NavigationStack，自己不再套一层。
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if sessions.isEmpty {
                    historyEmptyState
                } else {
                    sectionedList
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .appBackground()
        .foregroundStyle(Theme.ink)
        .navigationTitle("历史")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { sessions = feedback.archive.loadAllSessions() }
    }

    @ViewBuilder
    private var sectionedList: some View {
        let now = Date()
        let (recent, older) = partitionSessions(sessions, threshold: 30 * 24 * 3600, from: now)
        if !recent.isEmpty {
            sectionHeader(String(localized: "最近30天"))
            ForEach(recent, id: \.id) { s in
                NavigationLink {
                    SessionDetailView(session: s)
                        .environment(feedback)
                } label: {
                    sessionCard(s)
                }
                .buttonStyle(.plain)
            }
        }
        if !older.isEmpty {
            sectionHeader(String(localized: "更早")).padding(.top, 10)
            ForEach(older, id: \.id) { s in
                NavigationLink {
                    SessionDetailView(session: s)
                        .environment(feedback)
                } label: {
                    sessionCardCompact(s)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.bold())
            .foregroundStyle(Theme.inkSecondary)
            .padding(.leading, 4)
            .padding(.bottom, 2)
    }

    private var historyEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 56))
                .foregroundStyle(Theme.ink.opacity(0.3))
            Text("这里还是空的").font(.title3.bold())
                .foregroundStyle(Theme.ink)
            Text("练完的每一节都会在这里，一节一张卡。")
                .font(.caption).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

// MARK: - shared session cards (used by Practice "Recent" + History)

/// Recent-session card. Scores intentionally hidden — only count +
/// duration + the top fault label (qualitative) survive.
fileprivate func sessionCard(_ session: SessionDirectory) -> some View {
    let stats = SessionStatsCache.load(for: session)
    let live = session.endedAt == nil
    let improving = (stats?.improvementDelta ?? 0) > 2
    let declining = (stats?.improvementDelta ?? 0) < -2
    // Quality accent (the left rail + focal color): green improving, gold if a
    // recurring fault, blue for a neutral/clean session.
    let quality: Color = improving ? Theme.good
        : (stats?.faultRates.first != nil ? Theme.gold : Theme.accent)
    return HStack(spacing: 13) {
        // Left accent rail — the card's focal anchor + at-a-glance status.
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(quality.opacity(0.9))
            .frame(width: 4)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(dayLabel(session.startedAt))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(timeLabel(session.startedAt))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textMute)
                Spacer(minLength: 6)
                if live { liveTag } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ink.opacity(0.22))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(session.swingCount)")
                    .font(Theme.display(25, .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                Text("杆").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textMute)
                if let dur = stats?.durationMinutes, dur >= 1 {
                    Circle().fill(Theme.textMute.opacity(0.35)).frame(width: 3, height: 3)
                        .padding(.horizontal, 4)
                    Text("\(Int(dur.rounded())) 分钟")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 6)
                if improving || declining { trendChip(up: improving) }
            }
            if let topFault = stats?.faultRates.first {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .bold))
                    Text("主要问题：\(humanFault(topFault.id))").font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(Theme.warn.opacity(0.92))
            }
        }
    }
    .padding(.vertical, 15).padding(.leading, 12).padding(.trailing, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassCard(radius: 18)
}

/// "进行中" live tag with a soft accent glow.
fileprivate var liveTag: some View {
    HStack(spacing: 4) {
        Circle().fill(.white).frame(width: 5, height: 5)
        Text("进行中").font(.system(size: 10.5, weight: .bold)).tracking(0.2)
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 9).padding(.vertical, 3.5)
    .background(Capsule().fill(Theme.accentGrad))
    .shadow(color: Theme.accent.opacity(0.28), radius: 5, y: 2)
}

/// Direction-only trend chip (no raw scores) — up = greening, down = warning.
fileprivate func trendChip(up: Bool) -> some View {
    HStack(spacing: 3) {
        Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
            .font(.system(size: 9, weight: .bold))
        Text(up ? String(localized: "越练越好") : String(localized: "后程下滑"))
            .font(.system(size: 11, weight: .semibold))
    }
    .foregroundStyle(up ? Theme.good : Theme.warn)
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(Capsule().fill((up ? Theme.good : Theme.warn).opacity(0.12)))
}

fileprivate func sessionCardCompact(_ session: SessionDirectory) -> some View {
    HStack {
        Text(shortDate(session.startedAt)).font(.subheadline)
            .foregroundStyle(Theme.ink)
        Spacer()
        Text("\(session.swingCount) 杆")
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.inkSecondary)
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.ink.opacity(0.35))
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassCard(radius: 10)
}

// MARK: - shared helpers

fileprivate func partitionSessions(_ sessions: [SessionDirectory],
                                   threshold: TimeInterval,
                                   from now: Date) -> ([SessionDirectory], [SessionDirectory]) {
    var recent: [SessionDirectory] = []
    var older: [SessionDirectory] = []
    for s in sessions {
        if now.timeIntervalSince(s.startedAt) < threshold {
            recent.append(s)
        } else {
            older.append(s)
        }
    }
    return (recent, older)
}

fileprivate func humanizeDate(_ d: Date) -> String {
    let cal = Calendar.current
    let timePart = d.formatted(date: .omitted, time: .shortened)   // 按 locale 本地化时间
    if cal.isDateInToday(d) { return "\(String(localized: "今天")) \(timePart)" }
    if cal.isDateInYesterday(d) { return "\(String(localized: "昨天")) \(timePart)" }
    return d.formatted(date: .abbreviated, time: .shortened)        // 按 locale 本地化日期
}

fileprivate func shortDate(_ d: Date) -> String {
    d.formatted(date: .abbreviated, time: .omitted)
}

fileprivate func dayLabel(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return String(localized: "今天") }
    if cal.isDateInYesterday(d) { return String(localized: "昨天") }
    return d.formatted(.dateTime.month(.abbreviated).day())
}

fileprivate func timeLabel(_ d: Date) -> String {
    d.formatted(date: .omitted, time: .shortened)
}

fileprivate func humanFault(_ raw: String) -> String {
    SwingFaultID(rawValue: raw)?.label ?? raw
}

/// Helper to lazily load the SessionStats JSON for a session card without
/// blocking the main thread on every list refresh.
private enum SessionStatsCache {
    static func load(for session: SessionDirectory) -> SessionStats? {
        let url = session.root.appendingPathComponent("session_stats.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SessionStats.self, from: data)
    }
}
