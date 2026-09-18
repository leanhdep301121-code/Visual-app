import AVKit
import Photos
import SwiftUI

/// Deep analysis screen for the Upload mode. No TTS; everything is on-screen
/// for the user to dig into. Mirrors the PC dashboard's structure (video +
/// scrubbable timeline + metrics + LLM coach panels) but folds PC's
/// side-by-side user/Pro layout into a single overlay.
struct ProAnalysisView: View {
    let report: SwingReport
    /// Session this swing belongs to, when opened from the archive. Enables
    /// 「跟我的另一杆比」— comparing against one of your OWN swings instead of
    /// the bundled Pro. nil (Upload / debug entry) hides that option.
    var compareSession: SessionDirectory? = nil
    /// This swing's number within `compareSession`, so it can be excluded from
    /// the picker. SwingReport itself carries no swing number.
    var selfSwingNumber: Int? = nil
    @Environment(FeedbackOrchestrator.self) private var feedback
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer
    @State private var playerTime: Double = 0
    @State private var duration: Double = 0
    /// When the user taps an issue: the fault to visualize on-frame (joints +
    /// lines + reference guides + delta arrows), plus a short window to
    /// slow-LOOP so they SEE the motion, not a frozen frame. Scrubbing exits
    /// the loop but keeps the guides up; tap the same issue again to clear.
    @State private var selectedFault: SwingFault?
    /// Folds the raw metric / tempo / angle cards away by default — the screen
    /// leads with the qualitative read; numbers are one tap away.
    @State private var showDetails = false
    /// In-panel display mode: false = single video with overlays, true = user
    /// and Pro shown side by side (same phase, same guide lines on both).
    @State private var sideBySideMode = false
    @State private var proPlayer: AVPlayer?
    /// 自己跟自己比: another of the user's own swings loaded as the compare
    /// reference. When set it REPLACES the Pro in the right-hand pane — the
    /// event-warp, the evidence overlay and the panes are all reference-agnostic.
    @State private var selfCompareReport: SwingReport?
    @State private var selfComparePlayer: AVPlayer?
    @State private var showSwingPicker = false
    @State private var compareCandidates: [AnnotatedSwing] = []
    @State private var loadingCompare = false
    @State private var focusLoop: ClosedRange<Double>?
    @State private var observerToken: Any?
    /// Freeze-frame tail reveal: the clip usually ends while the predicted
    /// ball arc is still mid-air. When playback hits the end we keep the last
    /// frame (player pauses there anyway) and keep advancing this extra
    /// seconds-since-impact so the tracer finishes the descent + landing —
    /// same behavior as the offline render. Time-compressed with an ease-in
    /// ramp (a driver hangs 5-6 s; nobody watches that frozen).
    @State private var tailReveal: Double = 0
    @State private var tailTask: Task<Void, Never>?
    @State private var endObserver: NSObjectProtocol?
    /// Frame index of the event we most recently paused on. Stops the time
    /// observer from re-pausing the same event over and over.
    @State private var lastPausedEventFrame: Int = -1
    /// True while we're holding the player paused on an event so the user can
    /// read the highlight; flips back to false on resume.
    @State private var holdingOnEvent: Bool = false
    /// Default playback rate when not paused-on-event. 0.35 ≈ slow motion so
    /// the user can actually see the swing unfold between events.
    private let baseRate: Float = 0.35
    /// Seconds to hold paused on each event before resuming.
    private let eventHoldSeconds: TimeInterval = 2.5
    /// When false, the player runs at normal speed and never auto-pauses on
    /// events — for users who just want to watch their swing. Persisted so
    /// the preference sticks across views.
    private static let autoPauseKey = "proAnalysis.autoPauseOnPhases"
    // Default OFF: first impression must be the broadcast look — 1× playback
    // with the tracer drawing in sync (Toptracer). 0.35× + 2.5 s holds reads
    // as "the app is broken" next to it. Coaching slow-mo stays one tap away.
    @State private var autoPauseOnPhases: Bool =
        (UserDefaults.standard.object(forKey: ProAnalysisView.autoPauseKey) as? Bool) ?? false
    /// Whether to draw the red issue-marker dot + label on top of the video.
    /// User can toggle it off when the tag obscures the body during scrubbing.
    private static let showIssueKey = "proAnalysis.showIssueHighlight"
    @State private var showIssueHighlight: Bool =
        (UserDefaults.standard.object(forKey: ProAnalysisView.showIssueKey) as? Bool) ?? true
    /// Whether to draw the Pro silhouette overlay (synced at Address, true
    /// cadence). Off by default — it's an opt-in compare mode.
    private static let showProKey = "proAnalysis.showProOverlay"
    @State private var showProOverlay: Bool =
        (UserDefaults.standard.object(forKey: ProAnalysisView.showProKey) as? Bool) ?? false

    // Pro reference + the frozen registration that pins it to the user. Loaded
    // on appear; registration is built once `duration` is known (needs the
    // user's Address clip time). See `SwingAligner`.
    @State private var pro: ProReference?
    @State private var proMeta: ProSilhouetteMeta?
    @State private var proReg: SwingAligner.Registration?

    /// "Save to Photos" status. Used by the navBar button so the user gets
    /// feedback while the asset write is in flight.
    private enum SaveStatus: Equatable {
        case idle, saving, saved
        case failed(String)
    }
    @State private var saveStatus: SaveStatus = .idle

    init(report: SwingReport,
         compareSession: SessionDirectory? = nil,
         selfSwingNumber: Int? = nil) {
        self.report = report
        self.compareSession = compareSession
        self.selfSwingNumber = selfSwingNumber
        let p = AVPlayer(url: report.recordingURL!)
        // Replay is silent — original-clip audio (background range noise,
        // wind, etc.) just gets in the way of analysis. Mute on the player
        // so even system volume changes don't bring it back.
        p.isMuted = true
        p.volume = 0
        self._player = State(initialValue: p)
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            videoSection
            scrubSection
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black)

            ScrollView {
                VStack(spacing: 12) {
                    coachSummaryCard
                    swingBreakdownCard
                    drillCard
                    tipsCard
                    // Raw numbers are folded away by default — qualitative-first,
                    // so the screen isn't overwhelming. Tap to reveal the metric /
                    // tempo / per-event angle grids when you actually want them.
                    detailsToggle
                    if showDetails {
                        metricsCard
                        tempoCard
                        jointAnglesCard
                    }
                    Color.clear.frame(height: 16)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground))
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            loadProReference()
            attachObservers()
            feedback.generateSilently(report: report)
        }
        .onDisappear {
            detachObservers()
            selfComparePlayer?.pause()
        }
        .sheet(isPresented: $showSwingPicker) { swingPickerSheet }
    }

    // MARK: - sections

    private var navBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            saveToPhotosButton
            Spacer()
            Text("挥杆分析")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            // 把职业对照/并排/标记/自动暂停 4 个 power-user 开关收进 ⋯ 菜单，
            // 顶栏只留 关闭 · 保存 · 标题 · ⋯，清爽。状态在菜单项里打勾。
            Menu {
                Button {
                    showProOverlay.toggle()
                    UserDefaults.standard.set(showProOverlay, forKey: Self.showProKey)
                } label: {
                    Label(showProOverlay ? "关闭职业骨架对照" : "职业骨架对照",
                          systemImage: showProOverlay ? "checkmark" : "figure.golf")
                }
                .disabled(proReg == nil)

                Button {
                    // Toggling back to Pro: drop the self-compare so the right
                    // pane falls back to the bundled reference.
                    if sideBySideMode { sideBySideMode = false }
                    else { selfCompareReport = nil; selfComparePlayer = nil; sideBySideMode = true }
                } label: {
                    Label(sideBySideMode ? "关闭并排对比" : "并排对比职业",
                          systemImage: sideBySideMode ? "checkmark" : "rectangle.split.2x1.fill")
                }
                .disabled(pro == nil)

                // 自己跟自己比 — pick another swing from the same session.
                if compareSession != nil {
                    Button { loadCompareCandidates() } label: {
                        Label(selfCompareReport == nil ? "跟我的另一杆比" : "换一杆比",
                              systemImage: "person.2.fill")
                    }
                    .disabled(loadingCompare)
                }

                Button {
                    showIssueHighlight.toggle()
                    UserDefaults.standard.set(showIssueHighlight, forKey: Self.showIssueKey)
                } label: {
                    Label(showIssueHighlight ? "隐藏问题标记" : "显示问题标记",
                          systemImage: showIssueHighlight ? "checkmark" : "tag.fill")
                }

                Button {
                    autoPauseOnPhases.toggle()
                    UserDefaults.standard.set(autoPauseOnPhases, forKey: Self.autoPauseKey)
                    if !autoPauseOnPhases {
                        holdingOnEvent = false
                        player.playImmediately(atRate: 1.0)
                    } else {
                        player.playImmediately(atRate: baseRate)
                    }
                } label: {
                    Label(autoPauseOnPhases ? "关闭各阶段自动暂停" : "各阶段自动暂停",
                          systemImage: autoPauseOnPhases ? "checkmark" : "playpause.fill")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 50)
        .padding(.bottom, 8)
        .background(Color.black)
    }

    /// Compact "save the current clip to Photos" button. Mirrors the flow
    /// that used to live in the legacy SwingDetailView — request add-only
    /// auth, then PHAssetCreationRequest the mp4 URL. Icon swaps as the
    /// status changes so the user gets clear feedback without a banner.
    private var saveToPhotosButton: some View {
        Button {
            guard saveStatus != .saving, let url = report.recordingURL else { return }
            Task { await saveClipToPhotos(url: url) }
        } label: {
            Group {
                switch saveStatus {
                case .idle:
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                case .saving:
                    ProgressView().scaleEffect(0.7).tint(.white)
                case .saved:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 36, height: 36)
            .background(.ultraThinMaterial)
            .clipShape(Circle())
        }
        .disabled(saveStatus == .saving || report.recordingURL == nil)
    }

    private func saveClipToPhotos(url: URL) async {
        await MainActor.run { saveStatus = .saving }
        do {
            let status = await requestPhotoAddAuth()
            guard status == .authorized || status == .limited else {
                await MainActor.run { saveStatus = .failed(String(localized: "相册访问被拒绝")) }
                return
            }
            try await writeVideo(to: PHPhotoLibrary.shared(), from: url)
            await MainActor.run { saveStatus = .saved }
            // Reset the icon to the download glyph after a moment so the
            // user can re-save if they want, without the green check
            // sticking around for the whole session.
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                if case .saved = saveStatus { saveStatus = .idle }
            }
        } catch {
            await MainActor.run { saveStatus = .failed(error.localizedDescription) }
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

    /// False when recordingURL is nil or the file is gone (a dev rebuild can
    /// wipe the app's Documents) — drives the "video unavailable" note instead
    /// of a silent black frame.
    private var videoFileExists: Bool {
        guard let url = report.recordingURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var videoSection: some View {
        let vidAspect = max(0.1, report.videoSize.width / report.videoSize.height)
        // Force the outer container to be WIDER than the video so there's
        // guaranteed side letterbox to drop the issue label into. For
        // portrait video (vidAspect ≈ 0.56) this gives ~80–100 pt black
        // bars on each side; for already-wide videos no extra letterbox is
        // added (`max` keeps container ≥ video aspect).
        let containerAspect: CGFloat = max(vidAspect, 0.85)
        return GeometryReader { geo in
            let containerW = geo.size.width
            let containerH = geo.size.height
            // Aspect-fit video inside the outer container.
            let videoH = min(containerH, containerW / vidAspect)
            let videoW = videoH * vidAspect
            let videoX = (containerW - videoW) / 2
            let videoY = (containerH - videoH) / 2
            let videoRect = CGRect(x: videoX, y: videoY,
                                   width: videoW, height: videoH)

            if sideBySideMode, pro != nil {
              sideBySidePanes(geo: geo, vidAspect: vidAspect)
            } else {
              ZStack(alignment: .topLeading) {
                VideoPlayer(player: player)
                    .frame(width: videoW, height: videoH)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                    .offset(x: videoX, y: videoY)

                // Video file missing (e.g. a dev rebuild cleared the app's
                // Documents) → show a clear note instead of a silent black
                // frame; the pose-based analysis below is still fully intact.
                if !videoFileExists {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash.fill").font(.system(size: 34))
                        Text("视频不可用").font(.subheadline.weight(.semibold))
                        Text("视频片段已被清除（可能是重装了 app）。下面的分析仍然可用。")
                            .font(.caption2).foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center).padding(.horizontal, 28)
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: videoW, height: videoH)
                    .offset(x: videoX, y: videoY)
                }

                // Pro silhouette: pinned to the video rect, driven by a frozen
                // registration so it doesn't jitter. Drawn under the issue tag.
                if showProOverlay, let pro, let proMeta, let proReg {
                    ProSilhouetteOverlay(
                        pro: pro,
                        meta: proMeta,
                        reg: proReg,
                        userFrame: report.frame(forClipTime: playerTime, duration: duration),
                        userEvents: report.events.frames,
                        videoAspect: vidAspect,
                        // Down-the-line: two side-on bodies overlap, so the Pro
                        // fill is eased down (not all the way — 0.22 read as just
                        // a rim) and the crisp outline carries the separation.
                        // Face-on stays at the fuller fill.
                        fillOpacity: report.viewpoint == .downTheLine ? 0.45 : 0.62
                    )
                    .frame(width: videoW, height: videoH)
                    .offset(x: videoX, y: videoY)
                }

                // Issue overlay spans the FULL container so the label can
                // land in the side letterbox, not on top of the body.
                if showIssueHighlight {
                    IssueHighlightOverlay(
                        pose: currentPose(),
                        perEvent: report.perEvent,
                        events: report.events,
                        currentFrame: report.frame(forClipTime: playerTime,
                                                   duration: duration),
                        videoRect: videoRect,
                        // Ball-flight capsule occupies the top-left corner.
                        topLeftReserved: report.ballFlight != nil ? 44 : 0
                    )
                    .frame(width: containerW, height: containerH)
                }

                if let traj = report.ballTrajectory {
                    // reveal in sync with playback: time base = seconds since impact
                    let impactClipT = report.clipTime(forFrame: traj.impactFrameIndex,
                                                      duration: duration)
                    BallTrajectoryOverlay(trajectory: traj,
                                          // tailReveal (freeze-frame arc extension) only applies
                                          // AT the clip end — otherwise scrubbing back to before
                                          // impact leaves it stuck high and the whole tracer shows
                                          // during address/downswing.
                                          visibleUpTo: playerTime - impactClipT
                                              + (playerTime >= duration - 0.06 ? tailReveal : 0))
                        .frame(width: videoW, height: videoH)
                        .offset(x: videoX, y: videoY)
                }

                // Club tracer overlay OFF by default: sparse anchors read
                // inaccurate/ugly (user verdict). ClubTrack data stays in the
                // report (ball-corridor anchor, future tempo metrics).
                // if let ct = report.clubTrack { ClubTrackOverlay(track: ct, ...) }

                if let bf = report.ballFlight {
                    HStack(spacing: 8) {
                        // One number, not a band. A range just hands our
                        // uncertainty to the user, who can't act on it — they
                        // want to know how far they hit it. So the decision is
                        // binary: either we have a figure worth showing, or we
                        // show none and keep the tracer (direction and arc shape
                        // are geometry — they hold even when scale doesn't).
                        if bf.confidence == .low {
                            Label("弧形参考 · 距离未标定", systemImage: "scope")
                        } else {
                            Label(String(format: "%.0f m/s", bf.speedMps), systemImage: "gauge.with.needle")
                            Text("·").opacity(0.5)
                            Text(String(format: "%.0f°", bf.launchAngleDeg))
                            Text("·").opacity(0.5)
                            Text(String(format: "%.0f 码", bf.carryYards))
                        }
                    }
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .environment(\.colorScheme, .dark)
                    .offset(x: videoX + 10, y: videoY + 10)
                }

                // Evidence overlay: when an issue is selected, draw the joints /
                // lines / angle the rule judged it from, right on the frame.
                if let sf = selectedFault,
                   let ev = FaultEvidenceBuilder.evidence(for: sf, report: report) {
                    if let pose = currentPose() {
                        // EvidenceOverlay dims only the BACKGROUND (keeps the
                        // subject bright via an even-odd cut-out), then draws
                        // the guides on top.
                        EvidenceOverlay(pose: pose, addressPose: addressPose(),
                                        pathPoses: pathPoses(for: ev),
                                        pathProgress: pathProgress(),
                                        evidence: ev, videoRect: videoRect)
                            .frame(width: containerW, height: containerH)
                    }
                    // Rotation faults: a large top-down turn gauge that updates
                    // LIVE with playback (shoulder/hip turn measured at the
                    // current frame), centered low.
                    if let gauge = ev.turnGauge {
                        let turn = currentTurn()
                        // Size scales with the video; placed in the BOTTOM CORNER
                        // opposite the player (read hip-mid x of the current pose)
                        // so it never sits on top of the body.
                        let gW = min(max(videoW * 0.40, 116), 188)
                        let gH = gW + 50
                        // Use the ADDRESS pose (fixed) to pick the side, not the
                        // current frame — otherwise the player swaying left/right
                        // during the swing makes the gauge jump between corners.
                        let playerX = addressPose().map {
                            (Double($0.keypoints[Joint.leftHip].x)
                             + Double($0.keypoints[Joint.rightHip].x)) / 2
                        } ?? 0.5
                        let cx = playerX < 0.5
                            ? videoX + videoW - gW / 2 - 8     // player left → gauge right
                            : videoX + gW / 2 + 8              // player right → gauge left
                        TurnGaugeView(mode: gauge.mode,
                                      shoulderTurn: turn.shoulder, hipTurn: turn.hip)
                            .frame(width: gW, height: gH)
                            .position(x: cx, y: videoY + videoH - gH / 2 - 8)
                    }
                }
              }
            }
        }
        .aspectRatio(containerAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    /// Side-by-side panel: user (left) and Pro (right), both at the current
    /// swing phase (driven by the shared `playerTime` → event-warped Pro frame),
    /// with the SAME fault guide lines drawn on each from its own pose. Lives
    /// inside the video panel — toggled by the "vs" button, not a separate view.
    /// What the right-hand pane draws — the bundled Pro, or another of the
    /// user's own swings. Everything downstream (event-warp, evidence overlay,
    /// the pane itself) is reference-agnostic, so both go through this.
    private struct CompareRef {
        let label: String
        let color: Color
        let events: [Int]                 // drives the piecewise event warp
        let aspect: CGFloat
        let player: AVPlayer?
        /// Pro DTL ships per-frame PNGs and no mp4 → pane renders a still.
        /// A user swing always has an mp4 → nil.
        let usesStill: Bool
        let pose: (Int) -> PoseFrame?
    }

    /// Self-compare wins when loaded, else the Pro. nil = nothing to compare.
    private var activeCompareRef: CompareRef? {
        if let sc = selfCompareReport {
            let asp = sc.videoSize.height > 0 ? sc.videoSize.width / sc.videoSize.height : 0.56
            return CompareRef(
                label: String(localized: "另一杆"), color: .green,
                events: sc.events.frames, aspect: asp,
                player: selfComparePlayer, usesStill: false,
                pose: { f in sc.poseFrames.indices.contains(f) ? sc.poseFrames[f] : nil })
        }
        if let pro {
            return CompareRef(label: "Pro", color: .cyan, events: pro.events,
                              aspect: proSideAspect, player: proPlayer, usesStill: true,
                              pose: { proPoseFrame($0) })
        }
        return nil
    }

    @ViewBuilder
    private func sideBySidePanes(geo: GeometryProxy, vidAspect: CGFloat) -> some View {
        let uf = report.frame(forClipTime: playerTime, duration: duration)
        let ev = sideBySideEvidence
        if let ref = activeCompareRef {
            // Warp the reference onto the user's phase — pure [Int] events in,
            // frame out, so it works the same for Pro and for your own swing.
            let rf = SwingAligner.proFrame(forUserFrame: uf,
                                           userEvents: report.events.frames,
                                           proEvents: ref.events)
            let refAddr = ref.events.first ?? 0
            HStack(spacing: 4) {
                comparePane(player: player, stillFrame: nil, aspect: vidAspect,
                            pose: report.poseFrames.indices.contains(uf) ? report.poseFrames[uf] : nil,
                            addressPose: addressPose(), evidence: ev,
                            label: String(localized: "这一杆"), color: .yellow,
                            w: geo.size.width / 2, h: geo.size.height)
                comparePane(player: ref.player, stillFrame: ref.usesStill ? rf : nil,
                            aspect: ref.aspect,
                            pose: ref.pose(rf), addressPose: ref.pose(refAddr), evidence: ev,
                            label: ref.label, color: ref.color,
                            w: geo.size.width / 2, h: geo.size.height)
            }
        }
    }

    // MARK: - 自己跟自己比

    /// Other swings in this session that have a clip on disk (retention keeps
    /// only a subset — no point offering one we can't play).
    private func loadCompareCandidates() {
        guard let session = compareSession else { return }
        loadingCompare = true
        let archive = feedback.archive
        Task { @MainActor in
            let all = await Task.detached { archive.loadAnnotated(in: session) }.value
            compareCandidates = all.filter {
                $0.swingNumber != selfSwingNumber
                    && $0.category != .unreadable
                    && archive.clipURL(swingNumber: $0.swingNumber, in: session) != nil
            }
            loadingCompare = false
            showSwingPicker = true
        }
    }

    /// Load the picked swing as the compare reference and flip into side-by-side.
    private func pickCompareSwing(_ sw: AnnotatedSwing) {
        guard let session = compareSession else { return }
        showSwingPicker = false
        loadingCompare = true
        let archive = feedback.archive
        let size = report.videoSize
        Task { @MainActor in
            let r = await Task.detached {
                archive.loadSwingReport(annotated: sw, in: session, videoSize: size)
            }.value
            loadingCompare = false
            guard let r, let url = archive.clipURL(swingNumber: sw.swingNumber, in: session) else { return }
            let p = AVPlayer(url: url)
            p.isMuted = true
            selfCompareReport = r
            selfComparePlayer = p
            sideBySideMode = true
        }
    }

    /// Swing picker for 自己跟自己比.
    private var swingPickerSheet: some View {
        NavigationStack {
            List(compareCandidates, id: \.swingNumber) { sw in
                Button { pickCompareSwing(sw) } label: {
                    HStack {
                        Text("第 \(sw.swingNumber) 杆").font(.headline)
                        Spacer()
                        Text("\(sw.score.total)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
            .navigationTitle("挑一杆来比")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if compareCandidates.isEmpty {
                    ContentUnavailableView("本节没有其它可比的挥杆", systemImage: "person.2.slash")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showSwingPicker = false }
                }
            }
        }
    }

    private var proSideAspect: CGFloat {
        guard let pro, pro.imageSize.count == 2 else { return 0.66 }
        return CGFloat(pro.imageSize[0]) / CGFloat(pro.imageSize[1])
    }

    /// The FULL fault evidence (highlight joints, lines, reference verticals,
    /// readout — same as the single-video overlay) for the selected issue, else
    /// the top-ranked root-cause fault. Drawn on BOTH bodies so the user sees
    /// the same error markers on themselves and the Pro reference.
    private var sideBySideEvidence: FaultEvidence? {
        let fault = selectedFault ?? drillTargetFault
        return fault.flatMap { FaultEvidenceBuilder.evidence(for: $0, report: report) }
    }

    /// Pro reference pose → PoseFrame. Its keypoints are already standard [0,1]
    /// normalization (extract_pro output), which is exactly what EvidenceOverlay
    /// maps straight onto the video rect — no aspect correction needed.
    private func proPoseFrame(_ frame: Int) -> PoseFrame? {
        guard let pro, pro.frames.indices.contains(frame) else { return nil }
        let f = pro.frames[frame]
        let kp = (0..<f.x.count).map { SIMD2<Float>(f.x[$0], f.y[$0]) }
        let aspect = pro.imageSize.count == 2
            ? Float(pro.imageSize[0]) / Float(pro.imageSize[1]) : 1
        return PoseFrame(timestamp: .zero, keypoints: kp, confidences: f.conf,
                         imageAspect: aspect)
    }

    /// Shoulder + hip turn (degrees from address) for ANY current/address pose
    /// pair — used for both the user and the Pro in side-by-side gauges.
    private func turn(current: PoseFrame?, address: PoseFrame?) -> (shoulder: Double, hip: Double) {
        guard let cur = current, let addr = address else { return (0, 0) }
        func lineAngle(_ p: PoseFrame, _ a: Int, _ b: Int) -> Double {
            let asp = Double(p.imageAspect)
            return atan2(Double(p.keypoints[b].y - p.keypoints[a].y),
                         Double(p.keypoints[b].x - p.keypoints[a].x) * asp) * 180 / .pi
        }
        func delta(_ from: Double, _ to: Double) -> Double {
            var d = to - from
            while d > 180 { d -= 360 }; while d < -180 { d += 360 }
            return abs(d)
        }
        let sh = delta(lineAngle(addr, Joint.leftShoulder, Joint.rightShoulder),
                       lineAngle(cur, Joint.leftShoulder, Joint.rightShoulder))
        let hp = delta(lineAngle(addr, Joint.leftHip, Joint.rightHip),
                       lineAngle(cur, Joint.leftHip, Joint.rightHip))
        return (sh, hp)
    }

    /// One pane of the side-by-side. `player` drives a live VideoPlayer (the user
    /// clip, and the Pro clip when an mp4 is bundled). When `player` is nil the
    /// pane falls back to the event-synced Pro PNG at `stillFrame`, bbox-placed
    /// so it lands under the same normalized pose overlay — this is how the DTL
    /// driver (frames, no mp4) renders its Pro pane.
    private func comparePane(player: AVPlayer?, stillFrame: Int?, aspect: CGFloat,
                             pose: PoseFrame?, addressPose: PoseFrame?, evidence: FaultEvidence?,
                             label: String, color: Color, w: CGFloat, h: CGFloat) -> some View {
        let videoH = min(h, w / max(0.1, aspect))
        let videoW = videoH * aspect
        let rect = CGRect(x: (w - videoW) / 2, y: (h - videoH) / 2, width: videoW, height: videoH)
        return ZStack(alignment: .topLeading) {
            if let player {
                VideoPlayer(player: player)
                    .frame(width: videoW, height: videoH)
                    .offset(x: rect.minX, y: rect.minY)
                    .disabled(true)
            } else if let stillFrame {
                proStill(pf: stillFrame, rect: rect)
            }
            // Same full evidence overlay as the single-video view, on each body.
            if let pose, let evidence {
                EvidenceOverlay(pose: pose, addressPose: addressPose,
                                evidence: evidence, videoRect: rect, showReadout: false)
                    .frame(width: w, height: h)
                // Rotation faults: each pane shows ITS OWN turn gauge (your coil
                // vs the Pro's at the same phase), since EvidenceOverlay doesn't
                // draw the gauge itself.
                if let g = evidence.turnGauge {
                    let t = turn(current: pose, address: addressPose)
                    let gw = min(rect.width * 0.62, 132)
                    let gh = gw + 22   // compact: dial + value only
                    TurnGaugeView(mode: g.mode, shoulderTurn: t.shoulder,
                                  hipTurn: t.hip, compact: true)
                        .frame(width: gw, height: gh)
                        .position(x: rect.midX, y: rect.maxY - gh / 2 - 6)
                }
            }
            Text(label)
                .font(.caption2.bold()).foregroundStyle(.black)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(color).clipShape(Capsule())
                .position(x: rect.minX + 28, y: rect.minY + 16)
        }
        .frame(width: w, height: h)
    }

    /// Pro pane background when there's no bundled mp4: the cropped per-frame
    /// PNG (`<id>_<pf>.png`, same assets the overlay uses), positioned by its
    /// silhouette bbox so the body lands exactly under the normalized pose
    /// overlay drawn on top. Native aspect preserved — no squish.
    @ViewBuilder
    private func proStill(pf: Int, rect: CGRect) -> some View {
        if let pro,
           let meta = proMeta,
           meta.bboxes.indices.contains(pf),
           meta.frameSize.count == 2,
           meta.frameSize[0] > 0, meta.frameSize[1] > 0,
           let img = UIImage(named: String(format: "%@_%04d", pro.id, pf)) {
            let b = meta.bboxes[pf]
            if b.count == 4 {
                let fw = CGFloat(meta.frameSize[0]), fh = CGFloat(meta.frameSize[1])
                let x0 = CGFloat(b[0]) / fw, y0 = CGFloat(b[1]) / fh
                let x1 = CGFloat(b[2]) / fw, y1 = CGFloat(b[3]) / fh
                Image(uiImage: img)
                    .resizable()
                    .frame(width: max(1, (x1 - x0) * rect.width),
                           height: max(1, (y1 - y0) * rect.height))
                    .position(x: rect.minX + (x0 + x1) / 2 * rect.width,
                              y: rect.minY + (y0 + y1) / 2 * rect.height)
            }
        }
    }

    // `proAlignment` + `fittedSize` removed with the Tiger / skeleton overlays.

    private var scrubSection: some View {
        SwingScrubView(
            report: report,
            currentTime: playerTime,
            duration: duration
        ) { t in
            seek(to: t)
        }
    }

    private var coachSummaryCard: some View {
        Card(title: String(localized: "教练点评"), icon: "text.bubble.fill") {
            if feedback.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("生成中…").font(.subheadline).foregroundStyle(.secondary)
                }
            } else if let r = feedback.currentResponse {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: r.source == .cloud ? "cloud.fill" : "tray.fill")
                            .font(.caption2)
                        Text(r.source == .cloud ? String(localized: "云端 AI") : String(localized: "离线规则"))
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(.secondary)
                    Text(r.summary).font(.callout)
                }
            } else {
                Text("还没有分析。").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var metricsCard: some View {
        Card(title: String(localized: "指标"), icon: "ruler") {
            if let m = report.metrics {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    metricCell(String(localized: "X-factor（肩髋分离）"), String(format: "%+.0f°", m.xFactor),
                               note: classifyXFactor(m.xFactor))
                    metricCell(String(localized: "脊柱前倾"), String(format: "%.0f°", m.spineTilt),
                               note: classifySpineTilt(m.spineTilt))
                    metricCell(String(localized: "节奏（上杆:下杆）"), String(format: "%.2f", m.tempoRatio),
                               note: classifyTempo(m.tempoRatio))
                    metricCell(String(localized: "转髋"), String(format: "%+.0f°", m.hipTurn), note: nil)
                    metricCell(String(localized: "转肩"), String(format: "%+.0f°", m.shoulderTurn), note: nil)
                    metricCell(String(localized: "帧数"), "\(report.poseFrames.count)", note: nil)
                }
            } else {
                Text("指标暂不可用 — 挥杆事件不完整。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// Phase-length comparison (You vs Pro). This is where the tempo signal
    /// lives — the overlay intentionally doesn't warp it away.
    @ViewBuilder
    private var tempoCard: some View {
        if let phases = tempoPhases() {
            Card(title: String(localized: "节奏与各阶段时长"), icon: "metronome") {
                TempoComparisonView(phases: phases)
            }
        }
    }

    private var jointAnglesCard: some View {
        Card(title: String(localized: "各事件关节角度"), icon: "figure.golf") {
            VStack(spacing: 8) {
                ForEach(report.perEvent.indices, id: \.self) { i in
                    let pe = report.perEvent[i]
                    if pe.frame >= 0 { eventAnglesRow(pe) }
                }
            }
        }
    }

    private func eventAnglesRow(_ pe: PerEventMetrics) -> some View {
        Button(action: { seekToFrame(pe.frame) }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(pe.event).font(.subheadline.bold())
                    Spacer()
                    Text("第\(pe.frame)帧")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 4
                ) {
                    miniAngle("X-factor",   pe.xFactor,     signed: true)
                    miniAngle(String(localized: "脊柱"),       pe.spineTilt,   signed: false)
                    miniAngle(String(localized: "肩"),         pe.shoulderTilt, signed: true)
                    miniAngle(String(localized: "髋"),         pe.hipTilt,     signed: true)
                    miniAngle(String(localized: "前肘"),       pe.leadElbow,   signed: false)
                    miniAngle(String(localized: "后肘"),       pe.trailElbow, signed: false)
                    miniAngle(String(localized: "前膝"),       pe.leadKnee,    signed: false)
                    miniAngle(String(localized: "后膝"),       pe.trailKnee,   signed: false)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func miniAngle(_ label: String, _ v: Double?, signed: Bool) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(v.map { signed ? String(format: "%+.0f°", $0) : String(format: "%.0f°", $0) } ?? "—")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(v == nil ? .secondary : .primary)
        }
    }

    private var eventsCard: some View {
        Card(title: String(localized: "挥杆事件"), icon: "timeline.selection") {
            VStack(spacing: 0) {
                ForEach(SwingEvent.allCases, id: \.rawValue) { ev in
                    Button(action: { seekToEvent(ev) }) {
                        HStack {
                            Text(ev.displayName).font(.subheadline)
                            Spacer()
                            if let f = report.events.frame(for: ev) {
                                Text("第\(f)帧")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.2fs", frameToTime(f)))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 60, alignment: .trailing)
                            } else {
                                Text("—").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if ev != .finish {
                        Divider()
                    }
                }
            }
        }
    }

    private var tipsCard: some View {
        Card(title: String(localized: "教练建议"), icon: "lightbulb.fill") {
            if feedback.isLoading {
                ProgressView()
            } else if let tips = feedback.currentResponse?.eventTips, !tips.isEmpty {
                VStack(spacing: 10) {
                    ForEach(tips) { tip in
                        TipRow(tip: tip) {
                            if let f = tip.userFrame { seekToFrame(f) }
                        }
                    }
                }
            } else {
                Text("没有发现明显问题。").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// Expand/collapse the detailed numbers (metrics, tempo, per-event angles).
    private var detailsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { showDetails.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: showDetails ? "chevron.up.circle.fill" : "chevron.down.circle")
                Text(showDetails ? String(localized: "收起详细数据") : String(localized: "展开详细数据"))
                Spacer()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Brand.primary)
            .padding(.vertical, 10).padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// Curriculum hook on the upload-analysis screen: a drill targeting the
    /// top-ranked (root-cause) fault, same DrillLibrary the session-onboarding
    /// screen uses. Watch link opens the public video externally.
    /// Top-ranked (root-cause) fault for the drill target. Prefers the cached
    /// score, but falls back to a direct detect so the drill shows even before
    /// `generateSilently` has populated `lastScore`.
    private var drillTargetFault: SwingFault? {
        (feedback.lastScore?.faults ?? SwingFaultDetector().detect(report: report)).first
    }

    @ViewBuilder
    private var drillCard: some View {
        if let top = drillTargetFault,
           let drill = DrillLibrary.drill(for: top.id) {
            Card(title: String(localized: "推荐训练"), icon: "figure.golf") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("针对你的主要问题 — \(top.id.plainLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(drill.name)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(drill.howTo)
                        .font(.caption).foregroundStyle(.secondary)
                    if let url = drill.url {
                        Link(destination: url) {
                            Label("观看这个训练", systemImage: "play.rectangle.fill")
                                .font(.subheadline.bold()).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(Brand.gradient)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Single unified view of everything we found: causally-linked issues as an
    /// indented tree (root at top → what it leads to), then any independent
    /// issues flat below. Replaces the old separate "Issues found" + "How it
    /// connects" cards, which showed the same data twice. Each row is tappable
    /// → seeks the video to where that issue is clearest.
    @ViewBuilder
    private var swingBreakdownCard: some View {
        if let score = feedback.lastScore {
            Card(title: String(localized: "问题拆解"), icon: "list.bullet.clipboard") {
                if score.faults.isEmpty {
                    Text("这一杆没有明显问题 — 动作很平衡。")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    let tree = causalTree(score.faults)
                    let treeIds = Set(tree.map { $0.fault.id })
                    let independent = score.faults.filter { !treeIds.contains($0.id) }
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(tree.enumerated()), id: \.offset) { _, node in
                            breakdownNode(node.fault, depth: node.depth)
                        }
                        if !independent.isEmpty {
                            if !tree.isEmpty {
                                Text("其他问题")
                                    .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                                    .padding(.top, 6)
                            }
                            ForEach(Array(independent.enumerated()), id: \.offset) { _, f in
                                breakdownNode(f, depth: 0)
                            }
                        }
                        Text(tree.isEmpty
                             ? String(localized: "点任意一条，在视频上看它。")
                             : String(localized: "点任意一条，在视频上看它。先改最上面那条 — 它下面的问题往往会跟着自己消失。"))
                            .font(.caption2).foregroundStyle(.secondary).padding(.top, 6)
                    }
                }
            }
        }
    }

    /// Flattens the faults' cause→effect links into a DFS tree list
    /// [(fault, depth)]. Each fault appears once: its parent is the DEEPEST of
    /// its `causedBy` roots, so A→B→C nests correctly instead of A also linking
    /// straight to C (which is what split one chain into two groups before).
    /// Independent faults (no causal link) are excluded — they already show in
    /// the Issues list. Empty when nothing is causally linked.
    private func causalTree(_ faults: [SwingFault]) -> [(fault: SwingFault, depth: Int)] {
        let byId = Dictionary(faults.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let causeIds = Set(faults.flatMap { $0.causedBy ?? [] })
        func involved(_ f: SwingFault) -> Bool {
            (f.causedBy?.isEmpty == false) || causeIds.contains(f.id)
        }
        var depthMemo: [SwingFaultID: Int] = [:]
        func depth(_ f: SwingFault) -> Int {
            if let d = depthMemo[f.id] { return d }
            let parents = (f.causedBy ?? []).compactMap { byId[$0] }
            let d = parents.isEmpty ? 0 : 1 + (parents.map { depth($0) }.max() ?? 0)
            depthMemo[f.id] = d
            return d
        }
        func directParent(_ f: SwingFault) -> SwingFaultID? {
            let parents = (f.causedBy ?? []).compactMap { byId[$0] }
            return parents.max { depth($0) < depth($1) }?.id
        }
        var children: [SwingFaultID: [SwingFault]] = [:]
        var roots: [SwingFault] = []
        // EVERY fault goes into the tree — a fault with a parent is nested under
        // it, everything else is a top-level root. A root that happens not to
        // have produced any other detected symptom this swing (e.g. a lone sway)
        // must still appear at the TOP, not get dropped into a bottom bucket.
        for f in faults {
            if let p = directParent(f) { children[p, default: []].append(f) }
            else { roots.append(f) }
        }
        var out: [(fault: SwingFault, depth: Int)] = []
        func visit(_ f: SwingFault, _ d: Int) {
            out.append((f, d))
            let kids = (children[f.id] ?? [])
                .sorted { ($0.anchorEvent?.rawValue ?? 99) < ($1.anchorEvent?.rawValue ?? 99) }
            for k in kids { visit(k, d + 1) }
        }
        // Roots ordered by causal layer FIRST (root > mid > symptom), severity
        // only as a tie-break — so the most-root cause is always on top.
        func rootKey(_ f: SwingFault) -> (Double, Double) {
            (f.id.layer.weight, f.severity * (f.confidence ?? 0.6))
        }
        let sortedRoots = roots.sorted {
            let a = rootKey($0), b = rootKey($1)
            return a.0 != b.0 ? a.0 > b.0 : a.1 > b.1
        }
        for r in sortedRoots { visit(r, 0) }
        return out
    }

    /// One tappable issue row. Indented by `depth` to show causal nesting (a
    /// down-right arrow marks caused rows). The role line shows "Root cause" /
    /// "Contributing factor" for top-level issues, or "Symptom · <phase>" for
    /// caused ones. Tapping seeks the video to where this issue is clearest.
    private func breakdownNode(_ f: SwingFault, depth: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2).foregroundStyle(.orange.opacity(0.7)).padding(.top, 3)
            }
            Circle().fill(layerColor(f.id.layer)).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 0) {
                Text(f.id.plainLabel).font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(depth > 0 ? phaseHint(f) : layerName(f.id.layer))
                        .font(.caption2).foregroundStyle(.secondary)
                    if (f.confidence ?? 1) < 0.6 {
                        Text("待确认")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.yellow.opacity(0.85))
                    }
                    // 2D limit: this fault reads best from the other angle.
                    if let bv = f.id.bestViewpoint, bv != report.viewpoint {
                        Text("\(bv.label)看更准")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.cyan.opacity(0.85))
                    }
                }
            }
            Spacer(minLength: 4)
            Text(severityWord(f.severity))
                .font(.caption.weight(.bold))
                .foregroundStyle(severityColor(f.severity))
                .padding(.top, 2)
        }
        .padding(.leading, CGFloat(depth) * 16)
        .contentShape(Rectangle())
        .background(selectedFault?.id == f.id ? Color.white.opacity(0.06) : .clear)
        .onTapGesture { focusFault(f) }
    }

    /// "Symptom · <when in the swing>" so the parallel symptoms read in time
    /// order (e.g. "Symptom · impact" above "Symptom · mid follow-through").
    private func phaseHint(_ f: SwingFault) -> String {
        guard let e = f.anchorEvent else { return String(localized: "症状") }
        return String(localized: "症状 · \(e.displayName)")
    }

    private func layerColor(_ l: FaultLayer) -> Color {
        switch l { case .root: return .red; case .mid: return .orange; case .symptom: return .gray }
    }
    private func layerName(_ l: FaultLayer) -> String {
        switch l {
        case .root:    return String(localized: "根本原因")
        case .mid:     return String(localized: "诱因")
        case .symptom: return String(localized: "症状")
        }
    }
    private func severityWord(_ s: Double) -> String {
        if s >= 0.7 { return String(localized: "明显") }
        if s >= 0.4 { return String(localized: "中等") }
        return String(localized: "轻微")
    }
    private func severityColor(_ s: Double) -> Color {
        if s >= 0.7 { return .red }
        if s >= 0.4 { return .orange }
        return .yellow
    }

    // MARK: - subviews

    private func metricCell(_ label: String, _ value: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
            if let note { Text(note).font(.caption2).foregroundStyle(Brand.primary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - playback

    private func attachObservers() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        observerToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            playerTime = time.seconds.isFinite ? time.seconds : 0
            // Playing again (replay/scrub) → drop any frozen-tail reveal.
            if player.rate > 0, tailReveal > 0 {
                tailTask?.cancel(); tailTask = nil; tailReveal = 0
            }
            // Side-by-side: keep the Pro clip locked to the user's current phase.
            if sideBySideMode, let pp = proPlayer, let pro {
                let uf = report.frame(forClipTime: playerTime, duration: duration)
                let pf = SwingAligner.proFrame(forUserFrame: uf,
                                               userEvents: report.events.frames,
                                               proEvents: pro.events)
                pp.seek(to: CMTime(seconds: Double(pf) / max(1, pro.fps), preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            }
            // Issue selected → slow-loop its window so the motion is visible.
            if let focusLoop {
                if playerTime >= focusLoop.upperBound {
                    player.seek(to: CMTime(seconds: focusLoop.lowerBound, preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .zero)
                    player.playImmediately(atRate: baseRate)
                }
            } else {
                checkEventPause()
            }
        }
        Task {
            if let item = player.currentItem {
                let d = try? await item.asset.load(.duration)
                if let d, d.seconds.isFinite {
                    await MainActor.run { self.duration = d.seconds }
                }
            }
        }
        // Always start from the top. Without this, AVPlayer occasionally
        // remembered a non-zero position from a prior presentation of the
        // same item, so reopening the same swing from History dropped the
        // user mid-swing instead of at Address.
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        lastPausedEventFrame = -1
        holdingOnEvent = false
        player.playImmediately(atRate: autoPauseOnPhases ? baseRate : 1.0)
        // Clip end → finish the predicted arc over the frozen last frame,
        // then (AUTOREPLAY=1, debug loop) restart from the top.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main) { _ in
            startTailReveal()
        }
    }

    /// Advance `tailReveal` until the whole predicted arc (plus the landing
    /// ring pulse) has drawn. Ease-in time compression 1×→2.2× over 1.5 s —
    /// matches the offline render's freeze-extension pacing.
    private func startTailReveal() {
        tailTask?.cancel()
        guard let traj = report.ballTrajectory,
              let lastT = (traj.predictedPoints?.last ?? traj.points.last)?.timeOffsetSeconds
        else { return }
        let impactClipT = report.clipTime(forFrame: traj.impactFrameIndex, duration: duration)
        let need = lastT + 0.9 - (duration - impactClipT)   // +0.9 s ring pulse
        guard need > tailReveal else { autoreplayRestart(); return }
        tailTask = Task { @MainActor in
            var elapsed = 0.0
            while tailReveal < need, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                elapsed += 1.0 / 30.0
                let ramp = min(1.0, elapsed / 1.5)
                tailReveal += (1.0 + 1.2 * ramp * ramp) / 30.0
            }
            guard !Task.isCancelled else { return }
            // Let the finished arc + landing ring breathe before a loop wipe.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            autoreplayRestart()
        }
    }

    private func autoreplayRestart() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["AUTOREPLAY"] == "1" else { return }
        tailReveal = 0
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.playImmediately(atRate: 1.0)
        #endif
    }

    /// If the current playerTime has just crossed a detected event frame
    /// (and we haven't already paused on it), hold the player still for a
    /// few seconds, then resume at the slow base rate.
    private func checkEventPause() {
        // No-op when the user has disabled auto-pause — they just want
        // straight playback at normal speed.
        guard autoPauseOnPhases else { return }
        guard duration > 0, report.poseFrames.count > 1, !holdingOnEvent else { return }
        // Convert player time → pose-frame index using the timestamp-aware
        // mapping. Live clips have padding around the swing; the linear
        // approximation drifted the auto-pause off the actual event frame.
        let currentFrame = report.frame(forClipTime: playerTime, duration: duration)

        // Look at every event in order; pause the first time we cross one
        // we haven't already paused on. 2-frame window stops us missing
        // an event between observer ticks.
        for f in report.events.frames where f > 0 && f > lastPausedEventFrame {
            if currentFrame >= f && currentFrame <= f + 2 {
                lastPausedEventFrame = f
                holdingOnEvent = true
                player.pause()
                // IMPORTANT: do NOT call seek() / seekToFrame() here. Those
                // go through the user-facing path which RESETS
                // lastPausedEventFrame + holdingOnEvent — that turned the
                // first event into a deadlock (resume → tick → re-pause).
                // The IssueHighlightOverlay uses `nearestPerEvent`, so being
                // 1-2 frames past the event is fine; the highlight still
                // resolves to the right phase's metrics.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(eventHoldSeconds))
                    guard observerToken != nil else { return }   // dismissed
                    holdingOnEvent = false
                    // Read the toggle at resume time — user may have flipped
                    // auto-pause off while we were holding. If they did, the
                    // button handler already started normal-speed playback;
                    // just don't override it here.
                    if autoPauseOnPhases {
                        player.playImmediately(atRate: baseRate)
                    }
                }
                return
            }
        }
    }

    private func detachObservers() {
        if let token = observerToken {
            player.removeTimeObserver(token)
            observerToken = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        tailTask?.cancel(); tailTask = nil
        player.pause()
    }

    private func currentPose() -> PoseFrame? {
        guard !report.poseFrames.isEmpty else { return nil }
        guard report.poseFrames.count > 1, duration > 0 else {
            return report.poseFrames.first
        }
        // Map player time → pose index via timestamps (NOT linear pose-index
        // → time). Live clips have ±0.5 s padding around the swing, so the
        // linear assumption pose[0]=0 / pose[N-1]=duration is wrong for
        // those — it offsets every event by ~0.5 s.
        let idx = report.frame(forClipTime: playerTime, duration: duration)
        return report.poseFrames[idx]
    }

    /// The address-frame pose — the baseline the reference guides are drawn
    /// from (dashed "start" lines + vertical axes).
    private func addressPose() -> PoseFrame? {
        guard let f = report.events.frame(for: .address),
              report.poseFrames.indices.contains(f) else { return nil }
        return report.poseFrames[f]
    }

    /// Shoulder + hip turn (deg) at the CURRENT frame relative to address —
    /// drives the live turn gauge so it grows as the swing plays. 2D-approximate
    /// (aspect-corrected line angles), same caveat as the gauge itself.
    private func currentTurn() -> (shoulder: Double, hip: Double) {
        guard let cur = currentPose(), let addr = addressPose() else { return (0, 0) }
        func lineAngle(_ p: PoseFrame, _ a: Int, _ b: Int) -> Double {
            let asp = Double(p.imageAspect)
            return atan2(Double(p.keypoints[b].y - p.keypoints[a].y),
                         Double(p.keypoints[b].x - p.keypoints[a].x) * asp) * 180 / .pi
        }
        func delta(_ from: Double, _ to: Double) -> Double {
            var d = to - from
            while d > 180 { d -= 360 }
            while d < -180 { d += 360 }
            return abs(d)
        }
        let sh = delta(lineAngle(addr, Joint.leftShoulder, Joint.rightShoulder),
                       lineAngle(cur, Joint.leftShoulder, Joint.rightShoulder))
        let hp = delta(lineAngle(addr, Joint.leftHip, Joint.rightHip),
                       lineAngle(cur, Joint.leftHip, Joint.rightHip))
        return (sh, hp)
    }

    /// How far through the downswing (top→impact) the playhead is, 0…1.
    /// <0 = before top, >1 = past impact. Lets the traced wrist path grow with
    /// playback instead of dumping the whole loop on one frame.
    private func pathProgress() -> Double {
        guard let top = report.events.frame(for: .top),
              let impact = report.events.frame(for: .impact), impact > top else { return -1 }
        let cur = report.frame(forClipTime: playerTime, duration: duration)
        return Double(cur - top) / Double(impact - top)
    }

    /// Downswing poses (top → impact) for path-fault tracing (over-the-top).
    /// Empty unless the evidence asks for a motion path.
    private func pathPoses(for ev: FaultEvidence) -> [PoseFrame] {
        guard ev.pathJoint != nil,
              let top = report.events.frame(for: .top),
              let impact = report.events.frame(for: .impact),
              top >= 0, impact > top, impact < report.poseFrames.count else { return [] }
        return Array(report.poseFrames[top...impact])
    }

    private func frameToTime(_ frame: Int) -> Double {
        report.clipTime(forFrame: frame, duration: duration)
    }

    /// Tap an issue → seek to where it's clearest and PAUSE there, with the
    /// on-frame evidence + reference guides drawn. The user then scrubs /
    /// slow-plays at their own pace (the guides stay, so the solid "now" lines
    /// move against the dashed "address" baseline as they scrub). Tap the same
    /// issue again to clear.
    private func focusFault(_ f: SwingFault) {
        if selectedFault?.id == f.id { selectedFault = nil; focusLoop = nil; return }
        guard let frame = f.anchorEvent.flatMap({ report.events.frame(for: $0) }), frame >= 0
        else { return }
        selectedFault = f
        holdingOnEvent = false
        // Slow-loop a window so the motion is visible. Head movement is judged
        // ONLY over address→impact (post-impact head turn during the follow-
        // through is normal and deliberately excluded), so loop exactly that
        // span for it instead of ±0.7 s around impact — otherwise you'd watch
        // the natural post-impact head turn and think it was being counted.
        let lo: Double
        let hi: Double
        if f.id == .headMovement,
           let aF = report.events.frame(for: .address),
           let iF = report.events.frame(for: .impact), iF > aF {
            lo = max(0, frameToTime(aF))
            hi = duration > 0 ? min(duration, frameToTime(iF)) : frameToTime(iF)
        } else {
            let center = frameToTime(frame)
            let half = 0.7
            lo = max(0, center - half)
            hi = min(duration > 0 ? duration : center + half, center + half)
        }
        focusLoop = hi > lo ? lo...hi : nil
        player.seek(to: CMTime(seconds: lo, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.playImmediately(atRate: baseRate)
    }

    private func seek(to t: Double) {
        // Manual scrub exits the auto-loop but KEEPS the guides up (selectedFault
        // stays) so the user can watch the "now" lines move against the
        // "address" baseline at their own pace.
        focusLoop = nil
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        // Manual scrub → reset the auto-pause cursor so replaying through
        // events from this point will hold on each one again. Use the user's
        // new position as the new high-water mark.
        let n = report.poseFrames.count
        if duration > 0, n > 1 {
            let frac = max(0, min(1, t / duration))
            let newFrame = Int((Double(n - 1) * frac).rounded())
            // Everything BEFORE the new position is "already-paused" so it
            // won't grab us; everything AFTER is fair game.
            lastPausedEventFrame = newFrame - 1
        }
        holdingOnEvent = false
    }

    private func seekToFrame(_ frame: Int) {
        seek(to: frameToTime(frame))
    }

    private func seekToEvent(_ ev: SwingEvent) {
        if let f = report.events.frame(for: ev) {
            seekToFrame(f)
        }
    }

    // MARK: - pro reference

    /// Bundled Pro reference id, picked by the clip's viewpoint so the overlay
    /// matches the user's camera angle: face-on clips compare against the
    /// face-on Pro, down-the-line against the DTL Pro. Both are bundled.
    private var proReferenceID: String {
        report.viewpoint == .faceOn ? "pro_faceon" : "pro_driver"
    }

    /// Phase names for the 7 spans between the 8 events, in canonical order.
    private static let phaseNames = [
        "Takeaway", "Early backswing", "Late backswing",
        "Transition", "Strike", "Early release", "To finish",
    ]
    /// Grouped colors: backswing (0..2), downswing (3..4), follow-through (5..6).
    private static let phaseColors: [Color] = [
        Brand.primaryLight, Brand.primary, Brand.primaryDeep,
        .cyan, .teal,
        .gray.opacity(0.7), .gray.opacity(0.5),
    ]

    private func loadProReference() {
        guard pro == nil else { return }
        let ref = ProReference.bundled(named: proReferenceID)
        pro = ref
        proMeta = ref?.bundledSilhouettes
        // The frozen registration depends only on the report + Pro reference
        // (mirror is decided from pose geometry), so it can be built right
        // away. Frame selection is event-warped at render time.
        if let ref {
            proReg = SwingAligner.register(report: report, pro: ref)
            // Registration may legitimately be nil (no Address detected / low
            // confidence) — the toggle stays disabled in that case.
            if proReg == nil { showProOverlay = false }
            // Pro player for the side-by-side mode (muted, seeked to match the
            // user's phase). Only available if a Pro mp4 is bundled.
            if let url = ref.bundledVideoURL {
                let p = AVPlayer(url: url)
                p.isMuted = true
                proPlayer = p
            }
        }
    }

    /// Per-phase durations for the user and the Pro, for the tempo ribbon.
    /// Returns nil if events are too incomplete to be meaningful.
    private func tempoPhases() -> [TempoPhase]? {
        guard let pro, pro.events.count == 8, pro.fps > 0, duration > 0 else { return nil }
        let ue = report.events.frames
        guard ue.count == 8 else { return nil }
        var out: [TempoPhase] = []
        for i in 0..<7 {
            let u0 = ue[i], u1 = ue[i + 1]
            let p0 = pro.events[i], p1 = pro.events[i + 1]
            let uSec = (u0 >= 0 && u1 >= 0) ? max(0, frameToTime(u1) - frameToTime(u0)) : 0
            let pSec = (p0 >= 0 && p1 >= 0) ? max(0, Double(p1 - p0) / pro.fps) : 0
            out.append(TempoPhase(id: i, name: Self.phaseNames[i],
                                  color: Self.phaseColors[i], userSec: uSec, proSec: pSec))
        }
        return out.contains(where: { $0.userSec > 0 }) ? out : nil
    }

    // MARK: - heuristic banding

    private func classifyXFactor(_ v: Double) -> String? {
        // "low" cutoff matches the (loosened) detector trigger — 2D foreshortens
        // rotation, so anything ≥18° reads as fine rather than under-rotated.
        let absV = abs(v)
        if absV < 18 { return String(localized: "偏低") }
        if absV > 50 { return String(localized: "偏高") }
        return String(localized: "良好")
    }

    private func classifySpineTilt(_ v: Double) -> String? {
        if v < 20 { return String(localized: "偏浅") }
        if v > 40 { return String(localized: "偏陡") }
        return String(localized: "良好")
    }

    private func classifyTempo(_ r: Double) -> String? {
        if r <= 0 { return nil }
        if r < 2.5 { return String(localized: "偏快") }
        if r > 3.5 { return String(localized: "偏慢") }
        return String(localized: "良好")
    }
}

// MARK: - reusable card chrome

private struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).font(.subheadline.bold())
            }
            .foregroundStyle(.primary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct TipRow: View {
    let tip: FeedbackTip
    let onTap: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation { expanded.toggle() } }) {
                HStack(spacing: 8) {
                    if let m = tip.metric {
                        Text(metricLabel(m))
                            .font(.caption2.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Brand.primary.opacity(0.18))
                            .foregroundStyle(Brand.primary)
                            .clipShape(Capsule())
                    }
                    Text(tip.tip)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let event = tip.event {
                HStack(spacing: 6) {
                    Text(event).font(.caption2).foregroundStyle(.secondary)
                    if let f = tip.userFrame {
                        Text("· frame \(f)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    label(String(localized: "原因"), tip.cause)
                    label(String(localized: "改进"), tip.fix)
                    if let drill = tip.drill { label(String(localized: "训练"), drill) }
                    if tip.userFrame != nil {
                        Button(action: onTap) {
                            HStack(spacing: 4) {
                                Image(systemName: "play.circle")
                                Text("跳到这一帧")
                            }
                            .font(.caption.bold())
                            .foregroundStyle(Brand.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func label(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(v).font(.caption)
        }
    }

    private func metricLabel(_ raw: String) -> String {
        switch raw {
        case "x_factor":     return "X-factor"
        case "spine_tilt":   return String(localized: "脊柱")
        case "shoulder_tilt": return String(localized: "肩")
        case "hip_tilt":     return String(localized: "髋")
        case "lead_elbow":   return String(localized: "前肘")
        case "trail_elbow":  return String(localized: "后肘")
        case "lead_knee":    return String(localized: "前膝")
        case "trail_knee":   return String(localized: "后膝")
        default:             return raw
        }
    }
}

/// Draws a fault's judgment basis directly on the video frame: the joints it
/// was measured from (ringed), the lines (spine / shoulder-vs-hip / arm), an
/// angle arc if relevant, and a readout tag with the plain-English basis.
/// Coordinates: the video fills `videoRect` exactly (aspect-fit, no inner
/// letterbox), so normalized keypoints map straight onto it. Upload clips
/// aren't mirrored. This is the rule engine's explainability, made visual.
private struct EvidenceOverlay: View {
    let pose: PoseFrame
    var addressPose: PoseFrame? = nil
    var pathPoses: [PoseFrame] = []
    var pathProgress: Double = 1   // 0…1 through the downswing; grows the trace
    let evidence: FaultEvidence
    let videoRect: CGRect
    /// The bottom readout tag. Off in side-by-side (the two panes compare
    /// visually; the text just repeats on both and eats the small frame).
    var showReadout: Bool = true

    var body: some View {
        Canvas { ctx, _ in
            func pt(_ p: PoseFrame, _ j: Int) -> CGPoint? {
                guard p.keypoints.indices.contains(j), p.confidences[j] > 0.2 else { return nil }
                let kp = p.keypoints[j]
                return CGPoint(x: videoRect.minX + CGFloat(kp.x) * videoRect.width,
                               y: videoRect.minY + CGFloat(kp.y) * videoRect.height)
            }
            func pt(_ j: Int) -> CGPoint? { pt(pose, j) }

            // Dim everything EXCEPT the area this issue is about — pull the
            // eye straight to the relevant body part (head / hips / lead arm…).
            // Gather just the joints this fault's guides touch (current AND
            // address positions, plus the traced path), box them with padding,
            // and cut that box out of the dim layer (even-odd). If the fault has
            // no geometry (pure tempo), skip dimming entirely.
            var relevant = Set(evidence.highlightJoints)
            evidence.lines.forEach { relevant.formUnion($0) }
            evidence.referenceLines.forEach { relevant.formUnion($0) }
            relevant.formUnion(evidence.verticals)
            relevant.formUnion(evidence.horizontals)
            relevant.formUnion(evidence.deltaJoints)
            if let pj = evidence.pathJoint { relevant.insert(pj) }
            if evidence.headCircle { relevant.insert(Joint.nose) }

            if !relevant.isEmpty {
                var minX = CGFloat.infinity, minY = CGFloat.infinity
                var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
                func grow(_ p: CGPoint?) {
                    guard let p else { return }
                    minX = min(minX, p.x); minY = min(minY, p.y)
                    maxX = max(maxX, p.x); maxY = max(maxY, p.y)
                }
                for j in relevant { grow(pt(pose, j)); if let ap = addressPose { grow(pt(ap, j)) } }
                if let pj = evidence.pathJoint { for pp in pathPoses { grow(pt(pp, pj)) } }
                var dim = Path()
                dim.addRect(videoRect)
                if minX < maxX {
                    let pad: CGFloat = max(46, (maxX - minX) * 0.35)
                    let box = CGRect(x: minX - pad, y: minY - pad,
                                     width: (maxX - minX) + 2 * pad,
                                     height: (maxY - minY) + 2 * pad).intersection(videoRect)
                    dim.addRoundedRect(in: box, cornerSize: CGSize(width: 30, height: 30))
                }
                ctx.fill(dim, with: .color(.black.opacity(0.58)), style: FillStyle(eoFill: true))
            }

            // Path overlays only make sense once the downswing is underway,
            // and both lines track the SAME object (the wrist). Show them only
            // while the playhead is between top and a hair past impact.
            let inDownswing = pathProgress >= 0 && pathProgress <= 1.25

            // Ideal WRIST arc (dashed green): the swing plane is a CIRCLE — the
            // wrist orbits the upper body. Draw the arc of that circle centered
            // at the shoulder-mid, radius = wrist-to-shoulder, from the top
            // wrist angle to the impact wrist angle (short way). The actual
            // wrist trace below is compared to it; over-the-top bows OUTSIDE.
            if inDownswing, evidence.idealArc, let pj = evidence.pathJoint, pathPoses.count > 1,
               let topW = pt(pathPoses.first!, pj),
               let impW = pt(pathPoses.last!, pj) {
                func shMid(_ p: PoseFrame) -> CGPoint? {
                    guard let l = pt(p, Joint.leftShoulder), let r = pt(p, Joint.rightShoulder)
                    else { return nil }
                    return CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
                }
                if let c1 = shMid(pathPoses.first!), let c2 = shMid(pathPoses.last!) {
                    let center = CGPoint(x: (c1.x + c2.x) / 2, y: (c1.y + c2.y) / 2)
                    let radius = (hypot(topW.x - center.x, topW.y - center.y)
                                + hypot(impW.x - center.x, impW.y - center.y)) / 2
                    let aT = atan2(topW.y - center.y, topW.x - center.x)
                    let aI = atan2(impW.y - center.y, impW.x - center.x)
                    var d = aI - aT                          // short-way sweep
                    while d > .pi { d -= 2 * .pi }
                    while d < -.pi { d += 2 * .pi }
                    var arc = Path()
                    let steps = 28
                    for i in 0...steps {
                        let a = aT + d * CGFloat(i) / CGFloat(steps)
                        let p = CGPoint(x: center.x + radius * cos(a),
                                        y: center.y + radius * sin(a))
                        if i == 0 { arc.move(to: p) } else { arc.addLine(to: p) }
                    }
                    ctx.stroke(arc, with: .color(.green.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 5]))
                }
            }

            // Actual WRIST trace — grows from top to the CURRENT frame so its
            // end stays on the hand (no full loop dumped on a static frame).
            if inDownswing, let pj = evidence.pathJoint, pathPoses.count > 1 {
                let last = max(1, min(pathPoses.count - 1,
                                      Int((Double(pathPoses.count - 1) * pathProgress).rounded())))
                var path = Path(); var started = false
                for i in 0...last {
                    guard let p = pt(pathPoses[i], pj) else { continue }
                    if started { path.addLine(to: p) } else { path.move(to: p); started = true }
                }
                ctx.stroke(path, with: .color(.black.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                ctx.stroke(path, with: .color(.cyan),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }

            // --- coach reference guides (dashed green, from the ADDRESS pose) ---
            if let ap = addressPose {
                // dashed "start" baseline lines
                for line in evidence.referenceLines {
                    var path = Path(); var started = false
                    for j in line {
                        guard let p = pt(ap, j) else { continue }
                        if started { path.addLine(to: p) } else { path.move(to: p); started = true }
                    }
                    ctx.stroke(path, with: .color(.green.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round,
                                                  lineJoin: .round, dash: [6, 5]))
                }
                // vertical reference axes through address joint x
                for j in evidence.verticals {
                    guard let p = pt(ap, j) else { continue }
                    var v = Path()
                    v.move(to: CGPoint(x: p.x, y: videoRect.minY))
                    v.addLine(to: CGPoint(x: p.x, y: videoRect.maxY))
                    ctx.stroke(v, with: .color(.green.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                }
                // horizontal level lines through address joint y (turn / head height)
                for j in evidence.horizontals {
                    guard let p = pt(ap, j) else { continue }
                    var h = Path()
                    h.move(to: CGPoint(x: videoRect.minX, y: p.y))
                    h.addLine(to: CGPoint(x: videoRect.maxX, y: p.y))
                    ctx.stroke(h, with: .color(.green.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                }
                // classic head circle around the ADDRESS head
                if evidence.headCircle,
                   let np = pt(ap, Joint.nose),
                   let ls = pt(ap, Joint.leftShoulder),
                   let rs = pt(ap, Joint.rightShoulder) {
                    let r = max(22, hypot(ls.x - rs.x, ls.y - rs.y) * 0.6)
                    let circle = Path(ellipseIn: CGRect(x: np.x - r, y: np.y - r,
                                                        width: r * 2, height: r * 2))
                    ctx.stroke(circle, with: .color(.green.opacity(0.95)),
                               style: StrokeStyle(lineWidth: 2.5, dash: [5, 4]))
                }
                // delta arrows: address → current, showing how far a joint moved
                for j in evidence.deltaJoints {
                    guard let a = pt(ap, j), let c = pt(j) else { continue }
                    guard hypot(c.x - a.x, c.y - a.y) > 4 else { continue }   // skip negligible
                    var stem = Path(); stem.move(to: a); stem.addLine(to: c)
                    ctx.stroke(stem, with: .color(.orange),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    let ang = atan2(c.y - a.y, c.x - a.x)
                    let ah: CGFloat = 9
                    var head = Path()
                    head.move(to: c)
                    head.addLine(to: CGPoint(x: c.x - ah * cos(ang - .pi / 6),
                                             y: c.y - ah * sin(ang - .pi / 6)))
                    head.move(to: c)
                    head.addLine(to: CGPoint(x: c.x - ah * cos(ang + .pi / 6),
                                             y: c.y - ah * sin(ang + .pi / 6)))
                    ctx.stroke(head, with: .color(.orange),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
            }

            // Lines (spine, shoulder/hip lines, arm/leg segments)
            for line in evidence.lines {
                var path = Path(); var started = false
                for j in line {
                    guard let p = pt(j) else { continue }
                    if started { path.addLine(to: p) } else { path.move(to: p); started = true }
                }
                ctx.stroke(path, with: .color(.black.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                ctx.stroke(path, with: .color(.yellow),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }

            // Angle arc at the vertex joint
            if let v = evidence.angleVertex, let vp = pt(v) {
                let r: CGFloat = 16
                let arc = Path(ellipseIn: CGRect(x: vp.x - r, y: vp.y - r, width: r * 2, height: r * 2))
                ctx.stroke(arc, with: .color(.yellow), lineWidth: 2)
            }

            // Highlighted joints — ringed + dotted
            for j in evidence.highlightJoints {
                guard let p = pt(j) else { continue }
                let r: CGFloat = 8
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                           with: .color(.red), lineWidth: 2.5)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                         with: .color(.red))
            }

            // Readout tag pinned to the bottom of the video rect
            if showReadout {
                var text = ctx.resolve(Text(evidence.readout)
                    .font(.caption2.weight(.semibold)).foregroundColor(.white))
                let maxW = videoRect.width - 24
                let m = text.measure(in: CGSize(width: maxW, height: 200))
                let tag = CGRect(x: videoRect.minX + 8,
                                 y: videoRect.maxY - m.height - 18,
                                 width: min(maxW, m.width) + 12, height: m.height + 8)
                ctx.fill(Path(roundedRect: tag, cornerRadius: 6), with: .color(.black.opacity(0.72)))
                ctx.draw(text, in: tag.insetBy(dx: 6, dy: 4))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Top-down rotation gauge for turn faults (shoulder / hip turn) that side-on
/// 2D video can't show directly. A dial seen from above: address points down
/// (toward camera), a filled wedge sweeps to how far you turned, a dashed mark
/// shows a healthy target. Green if you reached it, orange if short. The angle
/// is approximate — it's a "did you turn enough" illustration, not a precise
/// measurement.
private struct TurnGaugeView: View {
    let mode: TurnGauge.Mode
    let shoulderTurn: Double
    let hipTurn: Double
    /// Compact = side-by-side: just the dial + the value, no aim line / legend
    /// (the two panes are compared visually, and the narrow frame truncates the
    /// full text). Single-video keeps the full readout.
    var compact: Bool = false

    var body: some View {
        let xFactor = max(0, shoulderTurn - hipTurn)
        let isCoil = mode == .coil
        let value = isCoil ? xFactor : hipTurn
        // A side-on 2D view UNDER-reads true rotation, so these targets are what
        // is realistic on THIS measured scale — not the ~90° real-world hip turn
        // (even a pro won't hit 45° here). They calibrate the green/short flag;
        // the user-vs-pro gap on the dial is the real signal in side-by-side.
        let target: Double = isCoil ? 22 : 28
        let ok = value >= target
        let valueColor: Color = ok ? .green : .orange
        let shoulderColor = Color.cyan
        let hipColor = Color.orange
        return VStack(spacing: 6) {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2 - 6
                // address faces down (toward camera); backswing turns clockwise
                let base = CGFloat.pi / 2
                func ang(_ deg: Double) -> CGFloat { base + CGFloat(deg) * .pi / 180 }
                func ptOn(_ deg: Double, _ rad: CGFloat) -> CGPoint {
                    CGPoint(x: c.x + rad * cos(ang(deg)), y: c.y + rad * sin(ang(deg)))
                }
                func wedge(_ from: Double, _ to: Double, _ rad: CGFloat, _ col: Color) {
                    var p = Path(); p.move(to: c)
                    p.addArc(center: c, radius: rad,
                             startAngle: .radians(Double(ang(from))),
                             endAngle: .radians(Double(ang(to))), clockwise: false)
                    p.closeSubpath()
                    ctx.fill(p, with: .color(col))
                }
                // body outline (top-down)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(.white.opacity(0.22)), lineWidth: 1.5)
                // shoulder turn (outer, cyan) + hip turn (inner, orange)
                wedge(0, shoulderTurn, r * 0.92, shoulderColor.opacity(0.28))
                wedge(0, hipTurn, r * 0.58, hipColor.opacity(0.5))
                // X-factor gap = shoulders beyond hips (the coil) — highlight it
                if isCoil && shoulderTurn > hipTurn {
                    wedge(hipTurn, shoulderTurn, r * 0.92, valueColor.opacity(0.55))
                }
                // boundary lines
                var sl = Path(); sl.move(to: c); sl.addLine(to: ptOn(shoulderTurn, r * 0.92))
                ctx.stroke(sl, with: .color(shoulderColor), lineWidth: 2.5)
                var hl = Path(); hl.move(to: c); hl.addLine(to: ptOn(hipTurn, r * 0.58))
                ctx.stroke(hl, with: .color(hipColor), lineWidth: 2.5)
            }
            VStack(spacing: 1) {
                Text(isCoil ? String(localized: "蓄力 \(Int(value))°") : String(localized: "转髋 \(Int(value))°"))
                    .font(.system(size: compact ? 17 : 15, weight: .heavy))
                    .foregroundStyle(valueColor)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if !compact {
                    Text("目标 ~\(Int(target))°\(ok ? "" : " · 偏少")")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    HStack(spacing: 8) {
                        Label("肩", systemImage: "circle.fill").foregroundStyle(shoulderColor)
                        Label("髋", systemImage: "circle.fill").foregroundStyle(hipColor)
                    }
                    .font(.system(size: 7, weight: .semibold)).labelStyle(.titleAndIcon)
                    .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(compact ? 5 : 8)
        .background(.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// Draws the fault's guide geometry (lines, highlighted joints, vertical
/// references) on a single pose, mapped onto `videoRect`. Used for both the
/// user and the Pro in `SideBySideView`, each with its own pose, so the same
/// reference reads on both bodies. Low-confidence joints are skipped.
private struct PoseGuideOverlay: View {
    let joints: [(x: Double, y: Double, c: Double)]
    let lines: [[Int]]
    let highlights: [Int]
    let verticals: [Int]
    let videoRect: CGRect
    private let minConf = 0.2

    var body: some View {
        Canvas { ctx, _ in
            func ok(_ i: Int) -> Bool { joints.indices.contains(i) && joints[i].c >= minConf }
            func pt(_ i: Int) -> CGPoint {
                CGPoint(x: videoRect.minX + joints[i].x * videoRect.width,
                        y: videoRect.minY + joints[i].y * videoRect.height)
            }
            for v in verticals where ok(v) {
                let p = pt(v)
                var path = Path()
                path.move(to: CGPoint(x: p.x, y: videoRect.minY))
                path.addLine(to: CGPoint(x: p.x, y: videoRect.maxY))
                ctx.stroke(path, with: .color(.green.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            for poly in lines where poly.count >= 2 && poly.allSatisfy(ok) {
                var path = Path()
                path.move(to: pt(poly[0]))
                for k in poly.dropFirst() { path.addLine(to: pt(k)) }
                ctx.stroke(path, with: .color(.yellow), lineWidth: 3)
            }
            for h in highlights where ok(h) {
                let p = pt(h)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                         with: .color(.red))
            }
        }
        .allowsHitTesting(false)
    }
}
