import SwiftUI

struct WaveformScrubber: View {
    let peaks: [Float]
    let position: Double
    let duration: Double
    let loading: Bool
    let seek: (Double) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                GeometryReader { geometry in
                    Canvas { context, size in
                        let progress = min(1, max(0, duration > 0 ? position / duration : 0))
                        let maximum = max(peaks.max() ?? 0, 0.000001)
                        let bars = max(1, Int(size.width / 4))
                        for bar in 0..<bars {
                            let start = bar * peaks.count / bars
                            let end = min(peaks.count, max(start + 1, (bar + 1) * peaks.count / bars))
                            let peak = start < end ? peaks[start..<end].max() ?? 0 : 0
                            let height = max(2, CGFloat(sqrt(peak / maximum)) * (size.height - 18))
                            let x = CGFloat(bar) * size.width / CGFloat(bars)
                            let rect = CGRect(x: x, y: (size.height - height) / 2, width: 2, height: height)
                            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(x <= size.width * progress ? .red : .secondary.opacity(0.45)))
                        }
                        let x = max(1, min(size.width - 1, size.width * progress))
                        context.fill(Path(CGRect(x: x, y: 0, width: 1.5, height: size.height)), with: .color(.red))
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        seek(min(1, max(0, value.location.x / max(1, geometry.size.width))) * duration)
                    })
                }
                if loading { ProgressView("Loading waveform…").padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) }
            }.frame(height: 92)
                .accessibilityLabel("Audio waveform, current checkpoint")
                .accessibilityValue("\(Int(position)) of \(Int(duration)) seconds")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: seek(min(duration, position + 5))
                    case .decrement: seek(max(0, position - 5))
                    @unknown default: break
                    }
                }
            Text("Relative amplitude · click or drag to seek").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
