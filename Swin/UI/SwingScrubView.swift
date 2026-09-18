import SwiftUI

/// Custom scrub bar showing playhead + the 8 swing event positions as tickmarks.
/// Tap a tick or drag the thumb to seek.
struct SwingScrubView: View {
    let report: SwingReport
    let currentTime: Double
    let duration: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                Capsule().fill(Brand.gradient).frame(width: geo.size.width * progress, height: 4)

                ForEach(ticks(width: geo.size.width), id: \.ev) { tk in
                    Button(action: { onSeek(tk.clipTime) }) {
                        VStack(spacing: 1) {
                            Capsule().fill(.yellow).frame(width: 2, height: 14)
                            Text(short(tk.ev))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.yellow)
                                .fixedSize()
                                // TOP/M₂/IMP/M₃ all sit in the downswing → their
                                // ticks bunch and the labels overlapped ("IMPM₃").
                                // Stagger colliding ones onto a second row.
                                .offset(y: CGFloat(tk.row) * 9)
                        }
                    }
                    .buttonStyle(.plain)
                    .offset(x: geo.size.width * tk.t - 1, y: -8)
                }

                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .offset(x: geo.size.width * progress - 7, y: -5)
            }
            .frame(height: 36)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let t = max(0, min(1, g.location.x / geo.size.width))
                        onSeek(t * duration)
                    }
            )
        }
        .frame(height: 36)
    }

    private var progress: Double {
        duration > 0 ? min(1, max(0, currentTime / duration)) : 0
    }

    private struct Tick: Hashable {
        let ev: SwingEvent
        let clipTime: Double
        let t: Double
        let row: Int          // 0 = normal, 1 = staggered down (avoids overlap)
    }

    /// Event ticks with collision-aware label rows. Uses the timestamp-aware
    /// mapping — saved clips carry ±0.5 s padding, so a linear frame/(N-1)
    /// layout puts ticks ahead of the actual body positions in the mp4.
    private func ticks(width: CGFloat) -> [Tick] {
        guard duration > 0, report.poseFrames.count > 1, width > 0 else { return [] }
        var out: [Tick] = []
        var lastX = -CGFloat.greatestFiniteMagnitude
        var row = 0
        for ev in SwingEvent.allCases {
            guard let frame = report.events.frame(for: ev), frame >= 0 else { continue }
            let clipTime = report.clipTime(forFrame: frame, duration: duration)
            let t = clipTime / duration
            let x = width * t
            row = (x - lastX < 24) ? (row + 1) % 2 : 0   // too close → next row
            lastX = x
            out.append(Tick(ev: ev, clipTime: clipTime, t: t, row: row))
        }
        return out
    }

    private func short(_ ev: SwingEvent) -> String {
        switch ev {
        case .address: return "A"
        case .toeUp: return "T₁"
        case .midBackswing: return "M₁"
        case .top: return "TOP"
        case .midDownswing: return "M₂"
        case .impact: return "IMP"
        case .midFollowThrough: return "M₃"
        case .finish: return "FIN"
        }
    }
}
