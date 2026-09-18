import SwiftUI

/// Springy press feedback for the shutter — scales down on touch like the
/// system Camera button.
struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Full-screen "Pro beside you" — a life-size pro-swing hologram to train
/// against. On device: ARKit places it on the real floor (coaching overlay →
/// tap to place), walk around it, study it in slow-mo. In the simulator the
/// SAME hologram stands on a virtual range with an auto-orbiting camera.
struct SwingHologramView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var clip: HologramClip = {
        #if DEBUG
        // HOLOCLIP=<id>: open a specific clip (automation can't tap the picker).
        if let id = ProcessInfo.processInfo.environment["HOLOCLIP"],
           let c = HologramClip.all.first(where: { $0.id == id }) { return c }
        #endif
        return .default
    }()
    @State private var placed = false
    @State private var speed: Double = 1.0
    @State private var paused = false
    @State private var recorder = HologramRecorder()

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            content.ignoresSafeArea()
            if recorder.isRecording {
                recordingChrome                  // minimal: REC pill + stop, clean footage
            } else {
                controls
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .task(id: "hint-autohide") {
            // Simulator has no ARKit "placed" event — retire the hint after a
            // few seconds so the scene breathes.
            #if targetEnvironment(simulator)
            try? await Task.sleep(for: .seconds(6))
            withAnimation(.easeOut(duration: 0.4)) { placed = true }
            #endif
        }
        .fullScreenCover(isPresented: Binding(
            get: { recorder.preview != nil },
            set: { if !$0 { recorder.preview = nil } }
        )) {
            if let preview = recorder.preview {
                RecordingPreview(controller: preview) { recorder.preview = nil }
                    .ignoresSafeArea()
            }
        }
        #if DEBUG
        .task(id: "holorec-selftest") {
            // HOLOREC=1: exercise the REAL capture pipeline hands-free —
            // record 6 s of the session to Documents/holo_rec_test.mp4 so the
            // harness can pull the file and verify the pro is in the footage.
            guard ProcessInfo.processInfo.environment["HOLOREC"] == "1" else { return }
            try? await Task.sleep(for: .seconds(5))
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("holo_rec_test.mp4")
            recorder.startCaptureToFile(url)
            try? await Task.sleep(for: .seconds(6))
            recorder.stopCapture { msg in dbg(tag: "holo", "SELFTEST \(msg)") }
        }
        #endif
    }

    @ViewBuilder private var content: some View {
        #if targetEnvironment(simulator)
        HologramStageView(clip: clip, speed: speed, paused: paused)
        #else
        SwingHologramARView(clip: clip, speed: speed, paused: paused,
                            onPlaced: { placed = true })
        #endif
    }

    // MARK: overlay controls

    private var controls: some View {
        VStack(spacing: 0) {
            HStack {
                closeButton
                Spacer()
                VStack(spacing: 2) {
                    Text(clip.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Text("Life-size pro — study the swing")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                Color.clear.frame(width: 40, height: 40)   // balance the close btn
            }
            .padding(.horizontal, 16).padding(.top, 8)

            if !placed {
                hint.padding(.top, 24)
            }
            Spacer()
            VStack(spacing: 12) {
                if recorder.isAvailable {
                    recButton
                }
                speedBar
                clipPicker
            }
            .padding(.bottom, 24)
        }
    }

    /// ARvid loop: frame the pro through your camera, hit REC, get a video.
    private var recButton: some View {
        Button { recorder.start() } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 3.5).frame(width: 58, height: 58)
                Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 44, height: 44)
            }
        }
        .buttonStyle(ShutterPressStyle())
        .accessibilityLabel("Record")
    }

    /// Shown while recording: everything else hides so the footage is clean.
    @State private var recPulse = false
    private var recordingChrome: some View {
        VStack {
            Label("REC", systemImage: "record.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(red: 1, green: 0.27, blue: 0.23).opacity(recPulse ? 0.55 : 0.9), in: Capsule())
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: recPulse)
                .onAppear { recPulse = true }
                .onDisappear { recPulse = false }
                .padding(.top, 10)
            Spacer()
            Button { recorder.stop() } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 3.5).frame(width: 58, height: 58)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: 1, green: 0.27, blue: 0.23))
                        .frame(width: 26, height: 26)
                }
            }
            .accessibilityLabel("Stop recording")
            .padding(.bottom, 30)
        }
    }

    private var hint: some View {
        Label(hintText, systemImage: hintIcon)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var hintText: String {
        #if targetEnvironment(simulator)
        return "Tap the grass to move the pro · REC to film"
        #else
        return "Find your floor, then tap to place the pro"
        #endif
    }

    private var hintIcon: String {
        return "hand.tap.fill"
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    /// Slow-mo study controls: 0.25× / 0.5× / 1× + pause.
    private var speedBar: some View {
        HStack(spacing: 8) {
            ForEach([0.25, 0.5, 1.0], id: \.self) { s in
                Button {
                    speed = s
                    paused = false
                } label: {
                    Text(s == 1.0 ? "1×" : String(format: "%g×", s))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(speed == s && !paused ? .black : .white)
                        .frame(width: 52, height: 34)
                        .background(speed == s && !paused ? AnyShapeStyle(.white)
                                                          : AnyShapeStyle(.ultraThinMaterial),
                                    in: Capsule())
                }
            }
            Button { paused.toggle() } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(paused ? .black : .white)
                    .frame(width: 44, height: 34)
                    .background(paused ? AnyShapeStyle(.white)
                                       : AnyShapeStyle(.ultraThinMaterial),
                                in: Capsule())
            }
        }
    }

    private var clipPicker: some View {
        HStack(spacing: 8) {
            ForEach(HologramClip.all) { c in
                Button { clip = c } label: {
                    Text(c.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(clip.id == c.id ? .black : .white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(clip.id == c.id ? AnyShapeStyle(.white)
                                                    : AnyShapeStyle(.ultraThinMaterial),
                                    in: Capsule())
                }
            }
        }
    }
}
