import SwiftUI

/// Full-screen session report view. Score-driven content (avg / min / max,
/// numeric Score-summary card) is intentionally hidden — the app now leans
/// on qualitative tier labels + LLM coaching prose instead of scores.
struct SessionReportView: View {
    @Environment(FeedbackOrchestrator.self) private var feedback
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let report = feedback.lifecycle.lastReport
        let stats = feedback.lifecycle.lastStats
        let phase = feedback.lifecycle.phase
        let session = feedback.lifecycle.currentSession

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    topBar
                    if let stats { headerCard(stats) }
                    if phase == .generatingReport && (report == nil) {
                        loadingHero
                    }
                    if let report {
                        // headlineCard removed — its LLM-generated copy kept
                        // sliding numeric distance / range / score back into
                        // the report ("Averaged 46 yards with a range of
                        // 43–49..."). We don't show those.
                        fieldCard(title: String(localized: "做得好的"), text: report.topStrength,
                                  icon: "checkmark.seal.fill", color: .green)
                        fieldCard(title: String(localized: "要改的"), text: report.topProblemWithFix,
                                  icon: "exclamationmark.triangle.fill", color: .orange)
                        fieldCard(title: String(localized: "本节进展"), text: report.sessionProgress,
                                  icon: "arrow.up.right", color: Brand.primaryDeep)
                        fieldCard(title: String(localized: "下节目标"), text: report.nextSessionGoal,
                                  icon: "target", color: Brand.primary)
                    }
                    if phase == .reportReady, let session {
                        viewSwingsButton(session: session)
                        doneButton
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 22)
            }
            .appBackground()
            .foregroundStyle(Theme.ink)
            .navigationBarHidden(true)
        }
    }

    /// Navigates straight into the just-ended session's swing list. Keeps
    /// the user one tap away from rewatching each swing instead of
    /// forcing them to dismiss → History tab → find the session.
    private func viewSwingsButton(session: SessionDirectory) -> some View {
        NavigationLink {
            SessionDetailView(session: session)
                .environment(feedback)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 17, weight: .semibold))
                Text("查看每一杆")
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold)).opacity(0.4)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .glassCard(radius: 16)
        }
        .buttonStyle(.pressable)
        .padding(.top, 4)
    }

    private var topBar: some View {
        HStack {
            Text(headerTitle).font(.title2.bold())
            Spacer()
            if feedback.lifecycle.phase == .reportReady {
                Button { close() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2).foregroundStyle(Theme.ink.opacity(0.45))
                }
            }
        }
    }

    private var headerTitle: String {
        switch feedback.lifecycle.phase {
        case .generatingReport: return String(localized: "正在生成报告…")
        case .reportReady:      return String(localized: "本节报告")
        default:                return String(localized: "报告")
        }
    }

    @ViewBuilder
    private var loadingHero: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Brand.primary)
            Text("正在分析你的每一杆…").font(.callout)
                .foregroundStyle(Theme.ink.opacity(0.85))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 12)
    }

    /// Minimal stats — swing count + duration only. No avg/min/max/median.
    /// The score-driven numbers were doing more harm than good (people
    /// fixated on them); the LLM commentary tells the actual story.
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

    private func headlineCard(_ r: SessionReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.headline.isEmpty ? "…" : r.headline)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .transition(.opacity)
                .animation(.easeInOut, value: r.headline)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.gradient.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func fieldCard(title: String, text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.bold())
                    .foregroundStyle(color)
                Text(text.isEmpty ? "…" : text)
                    .font(.callout)
                    .foregroundStyle(Theme.ink)
                    .opacity(text.isEmpty ? 0.4 : 1.0)
                    .animation(.easeInOut, value: text)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 12)
    }

    private var doneButton: some View {
        Button { close() } label: {
            Text("完成")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.accentGrad))
                .shadow(color: Theme.accent.opacity(0.35), radius: 16, y: 8)
        }
        .buttonStyle(.pressable)
        .padding(.top, 8)
    }

    private func close() {
        feedback.lifecycle.dismissReport()
        dismiss()
    }
}
