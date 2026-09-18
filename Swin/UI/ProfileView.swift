import SwiftUI

/// "Me" tab — deliberately minimal: an identity card, ONE settings card
/// (language · voice · drills), and a version line. The app's whole philosophy
/// is "barely any buttons", so everything secondary collapses into compact
/// rows rather than a stack of big cards.
struct ProfileView: View {
    @Environment(FeedbackOrchestrator.self) private var feedback
    @State private var selectedVoiceID: String = CoachVoice.selected.id
    @State private var muted: Bool = false
    @State private var showHologram = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    accountCard
                    settingsCard
                    aboutFooter
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .appBackground()
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { muted = feedback.tts.isMuted }
            .fullScreenCover(isPresented: $showHologram) { SwingHologramView() }
        }
    }

    /// 账户卡。青绿渐变头像 + 称呼 + 惯用手。登录（T1）做好前是"游客"。
    private var accountCard: some View {
        let hand = feedback.userProfile.handedness == "left" ? String(localized: "左手球员") : String(localized: "右手球员")
        return HStack(spacing: 14) {
            Circle()
                .fill(Theme.accentGrad)
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "figure.golf").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white))
                .shadow(color: Theme.accentGlow, radius: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text("游客")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                Text(hand)
                    .font(.caption).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    /// 唯一的设置卡：语言 · 语音指导 · 教练语音 · 训练库。全部压成紧凑行。
    private var settingsCard: some View {
        VStack(spacing: 0) {
            // 语言：不再手动选择，自动跟随系统语言（App 首启时清掉旧的覆盖）。
            // 语音指导开关
            Toggle(isOn: Binding(get: { !muted }, set: { muted = !$0; feedback.tts.isMuted = !$0 })) {
                rowHead("语音指导", icon: "speaker.wave.2.fill")
            }
            .tint(Brand.primary)

            // 实测采集：留存每一杆的视频 + 球检测/弹道全参数(数据飞轮)。
            // 数据在 文件 app → 我的 iPhone → GoSwin → SwingArchive/sessions/。
            divider
            Toggle(isOn: Binding(
                get: { feedback.fieldCaptureMode },
                set: { feedback.fieldCaptureMode = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    rowHead("实测采集模式", icon: "externaldrive.fill.badge.plus")
                    Text("留存全部挥杆视频与弹道数据，文件 app 可导出")
                        .font(.caption2).foregroundStyle(Theme.inkSecondary)
                }
            }
            .tint(Brand.primary)

            // 教练语音（收进 Menu，取代原来的横滑大卡）
            if feedback.tts.cloudVoiceAvailable {
                divider
                Menu {
                    ForEach(CoachVoice.all) { v in
                        Button {
                            selectedVoiceID = v.id
                            feedback.tts.selectVoice(v)
                        } label: {
                            if selectedVoiceID == v.id {
                                Label(v.name, systemImage: "checkmark")
                            } else {
                                Text(v.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        rowHead("教练语音", icon: "waveform")
                        Spacer()
                        Text(CoachVoice.all.first { $0.id == selectedVoiceID }?.name ?? "默认")
                            .font(.subheadline).foregroundStyle(Theme.inkSecondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold)).foregroundStyle(Theme.ink.opacity(0.35))
                    }
                }
                .buttonStyle(.plain)
            }

            divider

            // 训练库
            NavigationLink {
                DrillsView()
            } label: {
                HStack(spacing: 12) {
                    rowHead("训练库", icon: "list.bullet.rectangle")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold)).foregroundStyle(Theme.ink.opacity(0.35))
                }
            }
            .buttonStyle(.plain)

            divider
            // AR 职业挥杆全息(真机 AR / 模拟器回放预览)
            Button { showHologram = true } label: {
                HStack(spacing: 12) {
                    rowHead("AR 职业陪练", icon: "arkit")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold)).foregroundStyle(Theme.ink.opacity(0.35))
                }
            }
            .buttonStyle(.plain)

            #if DEBUG
            divider
            NavigationLink {
                CaptureLabView()
            } label: {
                HStack(spacing: 12) {
                    rowHead("拍摄实验台 (debug)", icon: "camera.aperture")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold)).foregroundStyle(Theme.ink.opacity(0.35))
                }
            }
            .buttonStyle(.plain)
            #endif
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    /// 一行设置项的标题（图标 + 文字）。
    private func rowHead(_ title: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            Text(title)
                .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
        }
    }

    private var divider: some View {
        Divider().background(Theme.ink.opacity(0.06)).padding(.vertical, 12)
    }

    private var aboutFooter: some View {
        HStack {
            Spacer()
            Text("GoSwin · v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3")")
                .font(.caption2.monospacedDigit()).foregroundStyle(Theme.textMute)
            Spacer()
        }
        .padding(.top, 4)
    }
}
