import SwiftUI

/// Debug harness to exercise the capture-rig features on a real device:
/// preview, mode switch (analysis / multi-angle / cinematic), live lighting
/// advice, cinematic bokeh slider, and dual-stream recording. Reached via
/// `CAPTURELAB=1` (DEBUG). Not part of the shipping UI.
struct CaptureLabView: View {
    @State private var controller = CaptureController()
    @State private var mode: CaptureMode = .analysis

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            previewLayer

            // Tele stream as a picture-in-picture so both cameras show at once.
            if let tele = controller.telePreviewImage {
                VStack {
                    HStack {
                        Spacer()
                        VStack(spacing: 2) {
                            Image(decorative: tele, scale: 1, orientation: .up)
                                .resizable().scaledToFill()
                                .frame(width: 120, height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.6), lineWidth: 1))
                            Text("长焦特写").font(.caption2).foregroundStyle(.white)
                        }
                    }
                    Spacer()
                }
                .padding(.top, 60).padding(.trailing, 12)
            }

            VStack {
                HStack {
                    Text(cameraLabel).font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                if let advice = controller.lighting.advice {
                    lightingBanner(advice)
                }
                Spacer()
                controls
            }
            .padding()
        }
        .onAppear { controller.start(mode: mode) }
        .onDisappear { controller.stop() }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
    }

    /// Wide preview + the live face-metering box drawn over it, so we can see
    /// exactly where LightingAdvisor is sampling and what luma it reads.
    private var previewLayer: some View {
        GeometryReader { geo in
            ZStack {
                if let img = controller.previewImage {
                    Image(decorative: img, scale: 1, orientation: .up)
                        .resizable().scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                    if let box = controller.lighting.advice?.faceBox {
                        let fit = fittedRect(imageW: img.width, imageH: img.height, in: geo.size)
                        let r = CGRect(x: fit.minX + box.minX * fit.width,
                                       y: fit.minY + box.minY * fit.height,
                                       width: box.width * fit.width, height: box.height * fit.height)
                        Rectangle().stroke(Color.yellow, lineWidth: 2)
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                    }
                } else {
                    ProgressView().tint(.white)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func fittedRect(imageW: Int, imageH: Int, in size: CGSize) -> CGRect {
        let scale = min(size.width / CGFloat(imageW), size.height / CGFloat(imageH))
        let w = CGFloat(imageW) * scale, h = CGFloat(imageH) * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private var cameraLabel: String {
        switch mode {
        case .analysis:   return "广角 · 全身"
        case .multiAngle: return "广角(主) + 长焦(右上)"
        case .cinematic:  return "电影 · 虚化"
        }
    }

    private func lightingBanner(_ a: LightingAdvisor.Advice) -> some View {
        let color: Color = a.condition == .good ? .green : .orange
        let text = a.faceBox != nil
            ? "\(a.message) · 脸\(String(format: "%.2f", a.faceLuma)) 帧\(String(format: "%.2f", a.frameLuma))"
            : a.message
        return Label(text, systemImage: a.condition == .good ? "sun.max" : "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.7), lineWidth: 1.5))
            .padding(.top, 8)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if mode == .cinematic, controller.cinematicAperture > 0 {
                HStack {
                    Text(String(format: "虚化 f/%.1f", controller.cinematicAperture))
                        .font(.caption.monospacedDigit()).foregroundStyle(.white)
                    Slider(value: Binding(
                        get: { controller.cinematicAperture },
                        set: { controller.setCinematicAperture($0) }),
                        in: controller.cinematicRange)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            Picker("mode", selection: $mode) {
                ForEach(controller.capabilities.availableModes) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, new in controller.switchMode(new) }

            HStack(spacing: 40) {
                Button {
                    controller.toggleRolling()
                } label: {
                    Image(systemName: controller.isRolling ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 56))
                        .foregroundStyle(controller.isRolling ? .red : .white)
                }
                Button {
                    controller.keepRecent()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "star.circle.fill").font(.system(size: 44))
                        Text("存相册 \(controller.keptCount)").font(.caption2)
                    }
                    .foregroundStyle(controller.isRolling ? .yellow : .gray)
                }
                .disabled(!controller.isRolling)
            }
        }
    }
}
