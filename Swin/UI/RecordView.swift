import AVKit
import SwiftUI

struct RecordView: View {
    @Environment(CameraService.self) private var camera
    @Environment(FeedbackOrchestrator.self) private var feedback
    @Environment(\.scenePhase) private var scenePhase
    /// Set when presented as a full-screen cover from the Practice home.
    /// Calling it pops back to the home + history. No-op if there's no
    /// enclosing presentation (e.g. SwiftUI previews).
    @Environment(\.dismiss) private var dismiss

    @State private var thermal = ThermalMonitor()
    @State private var showFeedbackCard = false
    @State private var dismissTask: Task<Void, Never>?
    @State private var showReport = false
    /// 相机就绪 + 当前没在进行中的一节 → 自动开拍。多处触发，靠 phase 闸门去重。
    private func maybeAutoStart() {
        let p = feedback.lifecycle.phase
        guard camera.state == .ready, p == .idle || p == .reportReady else { return }
        startSessionWithDefaults()
    }

    /// 用默认设置直接开始一节（取代以前的机位/惯用手/重点/目标那一屏）。
    private func startSessionWithDefaults() {
        feedback.lifecycle.start(
            focus: nil, goalMinutes: nil, goalSwings: nil, focusNote: nil,
            viewpoint: .downTheLine,
            handedness: feedback.userProfile.handedness == "left" ? .left : .right)
        if feedback.coachingCadence != .off {
            feedback.tts.speak(String(localized: "准备好就开挥。"))
        }
    }
    // MARK: - in-session replay ("show me that last one")
    /// The swing just finished, its clip once it lands, and the marks the user
    /// made. The camera rolls the chunk early as soon as a clip is queued, so
    /// `replayURL` typically turns non-nil a few seconds after the swing.
    @State private var replaySwing: Int?
    @State private var replayURL: URL?
    @State private var showReplay = false
    @State private var replayPoll: Task<Void, Never>?
    @State private var keptSwings: Set<Int> = []

    /// Debug overlay — live detection-pipeline state, to diagnose on device
    /// (toggle with the ladybug in the top bar).
    @State private var showDebug = false
    /// Animated "REC" dot pulse while a session is active.
    @State private var recPulse = false
    #if DEBUG
    /// AUTOEND=N: auto-end the session after N swings (simulator can't tap End).
    /// Lets the retention pipeline (clip export + prune) run end-to-end headless.
    @State private var autoEndAt = Int(ProcessInfo.processInfo.environment["AUTOEND"] ?? "") ?? 0
    @State private var didAutoEnd = false
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            #if targetEnvironment(simulator)
            // 模拟器没真摄像头：显示虚拟摄像头（打包视频）的当前帧。
            if let f = camera.simFrame {
                Image(decorative: f, scale: 1, orientation: .up)
                    .resizable().scaledToFill().ignoresSafeArea()
            }
            #else
            CameraPreview(session: camera.session)
                .ignoresSafeArea()
            #endif

            VStack {
                topBar
                captureModeBar
                if showDebug { debugPanel }
                // 光照提示横幅已删（用户反馈：自动提亮已正常工作，横幅一直显示
                // "人脸偏暗"反而烦人）。自动提亮仍在 CameraService 后台跑，不受影响。
                if feedback.lifecycle.phase == .active {
                    sessionHUD
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if showFeedbackCard, let response = feedback.currentResponse {
                    FeedbackCard(
                        response: response,
                        swingCount: camera.liveTracker.swingCount
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 12)
                }
                bottomBar
            }
            .padding(.horizontal, 20)
            .animation(.easeInOut(duration: 0.25), value: feedback.lifecycle.phase)

            if camera.state == .denied { permissionDeniedOverlay }
            if camera.state == .configuring { ProgressView().tint(.white) }
        }
        .overlay(alignment: .topTrailing) { telePiP }
        .task {
            if camera.state == .idle {
                await camera.bootstrap()
            }
            let archive = feedback.archive
            camera.liveTracker.onSwingDiagnostic = { [weak archive] diag in
                guard let archive,
                      let session = archive.currentSession else { return }
                archive.archiveDiag(diag, into: session)
            }
            camera.onChunkClosed = { [weak archive] url in
                guard let archive else { return }
                Task { await archive.onChunkClosed(url: url) }
            }
            // Lets the camera roll a chunk EARLY once this chunk's swing clip is
            // queued — the mp4 then lands seconds after the swing instead of up
            // to a chunk-duration later, which is what in-session replay needs.
            camera.chunkHasQueuedClips = { [weak archive] url in
                archive?.hasPendingClips(source: url) ?? false
            }
            let tts = feedback.tts
            camera.liveTracker.isTTSActive = { tts.isSpeaking }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            // 极简：从练习页进来直接开拍，不再弹机位/惯用手/重点/目标那一屏。
            // 机位默认目标线后方，惯用手用档案值（自动检测兜底）。
            maybeAutoStart()
        }
        .onChange(of: camera.state) { _, _ in maybeAutoStart() }   // 相机就绪后再自动开拍
        #if DEBUG
        .task(id: "debug-forcemulti") {
            // FORCEMULTI=1：强制切多摄（绕过能力 gate），验证模拟器里"建不出来"
            // 时优雅回退分析、不崩。
            guard ProcessInfo.processInfo.environment["FORCEMULTI"] == "1" else { return }
            try? await Task.sleep(for: .seconds(4))
            camera.debugForceMode(.multiAngle)
        }
        #endif
        #if DEBUG
        .onChange(of: feedback.lifecycle.swingsThisSession) { _, n in
            guard autoEndAt > 0, !didAutoEnd, n >= autoEndAt,
                  feedback.lifecycle.phase == .active else { return }
            didAutoEnd = true
            print("[AUTOEND] reached \(n) swings — ending session for retention test")
            feedback.lifecycle.end()
        }
        #endif
        // In-session replay: when swing #n lands, wait for its clip to hit disk
        // then offer 「回看」. Poll rather than push — the export finishes on the
        // archive's own queue after the chunk closes.
        .onChange(of: feedback.lifecycle.swingsThisSession) { _, n in
            guard n > 0, feedback.lifecycle.phase == .active else { return }
            replaySwing = n
            replayURL = nil
            replayPoll?.cancel()
            let archive = feedback.archive
            replayPoll = Task { @MainActor in
                for _ in 0..<30 {                       // ~15 s, then give up
                    try? await Task.sleep(for: .milliseconds(500))
                    if Task.isCancelled { return }
                    guard let session = archive.currentSession else { continue }
                    if let u = archive.clipURL(swingNumber: n, in: session) {
                        replayURL = u
                        return
                    }
                }
            }
        }
        .overlay(alignment: .bottomLeading) { replayButton }
        .sheet(isPresented: $showReplay) {
            if let url = replayURL, let n = replaySwing {
                SwingReplaySheet(
                    url: url, swingNumber: n, isKept: keptSwings.contains(n),
                    onKeep: {
                        guard let s = feedback.archive.currentSession else { return }
                        feedback.archive.markKeep(swingNumber: n, in: s)
                        keptSwings.insert(n)
                    })
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            replayPoll?.cancel()
        }
        .task(id: "wire-live-swing") {
            camera.onLiveSwing = { report, score in
                guard feedback.lifecycle.phase == .active else { return }
                feedback.coachLive(report: report, score: score)
                withAnimation(.spring(duration: 0.4)) { showFeedbackCard = true }
                dismissTask?.cancel()
                dismissTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(10))
                    withAnimation(.easeOut(duration: 0.4)) { showFeedbackCard = false }
                }
            }
        }
        .onChange(of: feedback.lifecycle.phase) { _, phase in
            if phase == .active {
                camera.inferenceEnabled = true   // (re)enable live pose for the new session
                // Live swing metrics use the session's camera angle + handedness.
                camera.swingRecorder.viewpoint = feedback.lifecycle.sessionViewpoint
                camera.swingRecorder.handedness = feedback.lifecycle.sessionHandedness
                showFeedbackCard = false
                feedback.clearTransientState()
                // Belt-and-braces: clear every piece of state that can
                // leak across sessions or across a background suspend.
                // resetForNewSession does liveTracker.reset() too, so the
                // standalone call is redundant but harmless and keeps the
                // intent obvious here.
                feedback.tts.resetForNewSession()
                camera.resetForNewSession()
                camera.liveTracker.reset()
                camera.startSessionRecording()
                feedback.attachCameraRecording(
                    urlProvider: { camera.currentChunkURL },
                    startedAtProvider: { camera.sessionRecordingStartedAt },
                    firstPTSSecondsProvider: { camera.currentChunkFirstPTSSeconds }
                )
                feedback.lifecycle.sessionVideoFinalizer = { @Sendable in
                    _ = await camera.stopSessionRecording()
                }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    recPulse = true
                }
            } else {
                recPulse = false
            }
        }
        .onChange(of: feedback.lifecycle.phase) { _, phase in
            if phase == .generatingReport || phase == .reportReady {
                // Stop live pose inference so the report's per-clip re-analysis
                // (its own YOLO + PoseTCN) doesn't fight the LIVE YOLO + PoseTCN
                // for the ANE — that two-way CoreML contention is what hung
                // "Generating report…". Re-enabled when the next session starts.
                camera.inferenceEnabled = false
                showReport = true
            }
            if phase == .idle {
                showReport = false
            }
        }
        .sheet(isPresented: $showReport, onDismiss: {
            // Done reviewing the session report → pop back to Practice home.
            dismiss()
        }) {
            SessionReportView()
                .environment(feedback)
        }
        .onChange(of: scenePhase) { old, new in
            // Background → foreground: iOS may have suspended the capture
            // session and deactivated our audio session. Force-clear the
            // pose service's in-flight guard (its `defer` cleanup might
            // not have run if the queue was suspended mid-inference) and
            // resync the TTS audio-session flag, so the user's first
            // swing after resume isn't silently dropped.
            if old == .background && new == .active
                || old == .inactive && new == .active {
                camera.poseService.forceClearBusy()
                feedback.tts.resetForNewSession()
                if !camera.session.isRunning {
                    camera.startSession()
                }
            }
        }
    }


    // MARK: - top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            sessionStateBadge
            ThermalBadge(state: thermal.state)
            Spacer()
            debugButton
            cadenceButton
            switchCameraButton
        }
        .padding(.top, 50)
    }

    /// 拍摄模式切换：分析 / 多机位 / 电影。只有设备支持多于一种模式时才显示
    /// （模拟器、非 Pro 机只有分析 → 整条隐藏）。分析模式下分析照常跑；多机位/
    /// 电影是真机加分项，广角流在每种模式都驱动分析。
    @ViewBuilder
    private var captureModeBar: some View {
        let modes = camera.captureCaps.availableModes
        if modes.count > 1 {
            HStack(spacing: 6) {
                ForEach(modes) { mode in
                    let sel = camera.captureMode == mode
                    Button { camera.setCaptureMode(mode) } label: {
                        Text(mode.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(sel ? .black : .white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(sel ? Color.white : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 4)
        }
    }

    /// 长焦特写画中画（仅多机位）。广角仍是主预览 + 全部分析。
    @ViewBuilder
    private var telePiP: some View {
        if let tele = camera.telePreview {
            VStack(spacing: 2) {
                Image(decorative: tele, scale: 1, orientation: .up)
                    .resizable().scaledToFill()
                    .frame(width: 110, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.6), lineWidth: 1))
                Text("长焦特写").font(.caption2).foregroundStyle(.white)
            }
            .padding(.top, 96).padding(.trailing, 12)
        }
    }

    private var debugButton: some View {
        Button { showDebug.toggle() } label: {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(showDebug ? .green : .white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.6)).clipShape(Circle())
        }
    }

    /// Live detection-pipeline readout. The single most useful signal is the
    /// PoseTCN probs row: all-zero ⇒ pose/inference isn't running at all
    /// (camera / model load problem); flowing ⇒ detection is alive and the
    /// issue is downstream (state stuck, or emit aborting — see `last:`).
    private var debugPanel: some View {
        let tr = camera.liveTracker
        let probs = tr.currentProbs
        let am = tr.currentArgmax
        let names = ["A", "TU", "MB", "Tp", "MD", "Im", "MF", "Fn"]
        let allZero = probs.allSatisfy { $0 == 0 }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("DEBUG").font(.system(size: 9, weight: .heavy)).foregroundStyle(.green)
                Spacer()
                Text("cam:\(String(describing: camera.state))  phase:\(String(describing: feedback.lifecycle.phase))  tts:\(feedback.tts.isSpeaking ? "▶" : "–")")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
            }
            HStack(spacing: 5) {
                ForEach(0..<8, id: \.self) { i in
                    VStack(spacing: 1) {
                        Text(names[i]).font(.system(size: 7, weight: .bold))
                        Text(String(format: "%.2f", probs.indices.contains(i) ? probs[i] : 0))
                            .font(.system(size: 8, design: .monospaced))
                    }
                    .foregroundStyle(i == am ? .yellow : .white.opacity(0.55))
                }
            }
            HStack(spacing: 14) {
                Text("state:\(String(describing: tr.state))")
                Text("swings:\(tr.swingCount)")
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.cyan)
            Text("last: \(tr.lastEmitOutcome)")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.orange).lineLimit(1)
            Text(allZero ? "⚠️ probs all-zero → pose/PoseTCN NOT running (camera/model?)"
                         : "✓ probs flowing → detection alive (issue is downstream)")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(allZero ? .red : .green)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.82)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Combined "we're watching / we're recording" pill. Replaces the old
    /// dual detectorBadge + swingCountBadge — single chip is calmer.
    private var sessionStateBadge: some View {
        let active = feedback.lifecycle.phase == .active
        let n = feedback.lifecycle.swingsThisSession
        return HStack(spacing: 6) {
            Circle()
                .fill(active ? Brand.primary : Color.white.opacity(0.35))
                .frame(width: 8, height: 8)
            Text(active ? String(localized: "\(n) 杆") : String(localized: "就绪"))
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.6))
        .clipShape(Capsule())
    }

    private var cadenceButton: some View {
        let cadence = feedback.coachingCadence
        return Button {
            feedback.coachingCadence = cadence.next()
        } label: {
            VStack(spacing: 0) {
                Image(systemName: cadence.systemImage)
                    .font(.system(size: 13, weight: .bold))
                Text(cadence.label)
                    .font(.system(size: 8, weight: .heavy))
            }
            .foregroundStyle(cadence == .off ? .white.opacity(0.6) : Brand.primaryLight)
            .frame(width: 46, height: 36)
            .background(.black.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var switchCameraButton: some View {
        Button(action: { camera.switchCamera() }) {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.6))
                .clipShape(Circle())
        }
        .disabled(camera.state != .ready)
    }

    /// 「回看上一杆」— appears once the just-hit swing's clip is on disk.
    @ViewBuilder private var replayButton: some View {
        if feedback.lifecycle.phase == .active, let n = replaySwing, replayURL != nil {
            Button { showReplay = true } label: {
                Label(String(localized: "回看第 \(n) 杆"), systemImage: "play.rectangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .environment(\.colorScheme, .dark)
            }
            .padding(.leading, 16)
            .padding(.bottom, 28)
            .transition(.opacity.combined(with: .scale))
        }
    }

    // MARK: - session HUD (active-only)

    /// Compact horizontal HUD shown while a session is active. No raw
    /// scores — the qualitative tier label + streak / focused-fault chips.
    private var sessionHUD: some View {
        let state = feedback.coach.state
        let lastTier = state.swings.last?.tier
        let goodStreak = state.goodStreak
        let focused = state.focusedFault
        return HStack(spacing: 8) {
            if goodStreak >= 2 {
                hudPill("\(goodStreak)×", systemImage: "flame.fill", color: .green)
            }
            if let f = focused {
                hudPill(f.label, systemImage: "exclamationmark.triangle.fill", color: .orange)
            }
            Spacer()
            if let t = lastTier {
                Text(t.label)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(tierColor(t))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.top, 8)
    }

    private func hudPill(_ text: String, systemImage: String? = nil, color: Color) -> some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 11, weight: .bold))
            }
            Text(text).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.6))
        .clipShape(Capsule())
    }

    private func tierColor(_ t: SwingTier) -> Color {
        switch t {
        case .clean:   return .green
        case .solid:   return Brand.primaryLight
        case .mixed:   return .orange
        case .off:     return .red
        case .unclear: return .gray
        }
    }

    // MARK: - bottom controls

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if feedback.tts.isSpeaking {
                Button(action: { feedback.stopSpeaking() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.slash.fill")
                        Text("静音").font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.black.opacity(0.65))
                    .clipShape(Capsule())
                }
            }
            sessionControl
        }
        .padding(.bottom, 30)
    }

    @ViewBuilder
    private var sessionControl: some View {
        switch feedback.lifecycle.phase {
        case .idle, .reportReady:
            startSessionButton
        case .active:
            activeSessionPanel
        case .generatingReport:
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("正在生成报告…").font(.callout).foregroundStyle(.white)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.black.opacity(0.65))
            .clipShape(Capsule())
        }
    }

    private var startSessionButton: some View {
        Button {
            startSessionWithDefaults()   // 直接开拍，不再走机位/重点那一屏
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28, weight: .bold))
                Text("开始训练")
                    .font(.system(size: 18, weight: .heavy))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Brand.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Brand.primary.opacity(0.5), radius: 14, y: 6)
        }
        .padding(.horizontal, 8)
    }

    /// Active-session bottom panel. Wraps a live "REC" indicator + session
    /// stats + the End button into one card so the active state feels
    /// substantial instead of just a lonely red button.
    private var activeSessionPanel: some View {
        let n = feedback.lifecycle.swingsThisSession
        return HStack(spacing: 14) {
            // Pulsing REC dot + label
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .scaleEffect(recPulse ? 1.0 : 0.55)
                    .opacity(recPulse ? 1.0 : 0.65)
                VStack(alignment: .leading, spacing: 2) {
                    Text("录制中")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.red)
                        .tracking(1.2)
                    Group {
                        if let goal = feedback.lifecycle.goalSwings {
                            Text("\(n) / \(goal) 杆")
                        } else {
                            Text("已录 \(n) 杆")
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    // Focus line: the picked fault, else the user's own note.
                    if let focus = feedback.lifecycle.sessionFocus {
                        Text("重点：\(focus.plainLabel)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Brand.primaryLight)
                            .lineLimit(1)
                    } else if let note = feedback.lifecycle.focusNote {
                        Text("重点：\(note)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Brand.primaryLight)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            Button {
                feedback.lifecycle.end()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("结束")
                        .font(.system(size: 15, weight: .heavy))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 11)
                .background(Color.red)
                .clipShape(Capsule())
                .shadow(color: Color.red.opacity(0.4), radius: 8, y: 3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.7))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.red.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var permissionDeniedOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash").font(.system(size: 60))
            Text("需要相机权限")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.primary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.88))
        .foregroundStyle(.white)
    }
}

private struct FeedbackCard: View {
    let response: FeedbackResponse
    let swingCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: response.source == .cloud ? "sparkles" : "tray.fill")
                    .font(.caption)
                Text("第 \(swingCount) 杆")
                    .font(.caption.bold())
            }
            .foregroundStyle(Brand.primaryLight)

            Text(response.summary)
                .font(.callout)
                .foregroundStyle(.white)
                .lineLimit(4)

            if let topTip = response.eventTips.first {
                Divider().background(.white.opacity(0.2))
                Text(topTip.tip)
                    .font(.caption.bold())
                    .foregroundStyle(Brand.primary)
                Text(topTip.fix)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
            }
        }
        .padding(16)
        .frame(maxWidth: 360)
        .background(.black.opacity(0.78))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Brand.primary.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// Replay-as-session helpers (`ReplayPlayerView`, `ReplayMovie`,
// `SessionReplay`) removed — Live tab is now exclusively the camera-driven
// path. Users can analyze a saved video via the Upload tab.

/// In-session replay of the swing you just hit, plus 「留这杆」.
///
/// The keep mark is the missing half of the retention policy: `RetentionPolicy`
/// has always honoured user-kept swings (they survive both working-set eviction
/// and the final prune) but nothing in the app could ever SET the flag —
/// `SwingArchive.markKeep` had zero callers. This is that caller.
private struct SwingReplaySheet: View {
    let url: URL
    let swingNumber: Int
    let isKept: Bool
    let onKeep: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player).onAppear { player.play() }
                } else {
                    ProgressView()
                }
            }
            .background(.black)
            .navigationTitle(String(localized: "第 \(swingNumber) 杆"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onKeep) {
                        Label(isKept ? String(localized: "已留") : String(localized: "留这杆"),
                              systemImage: isKept ? "bookmark.fill" : "bookmark")
                    }
                    .disabled(isKept)
                }
            }
        }
        .task {
            let p = AVPlayer(url: url)
            p.isMuted = true
            // Loop — a single swing is ~3 s; you want to watch it a few times.
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: p.currentItem, queue: .main
            ) { _ in
                p.seek(to: .zero)
                p.play()
            }
            player = p
        }
        .onDisappear {
            player?.pause()
            if let o = loopObserver { NotificationCenter.default.removeObserver(o) }
        }
    }
}
