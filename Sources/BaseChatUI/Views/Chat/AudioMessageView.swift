import AVFoundation
import SwiftUI
import BaseChatInference

/// Inline playback control for ``MessagePart/audio(url:duration:waveform:)``.
@MainActor
struct AudioMessageView: View {
    let url: URL
    let duration: TimeInterval
    let waveform: [Float]?
    let role: MessageRole

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var elapsed: TimeInterval = 0
    @State private var loadError: String?

    private var displayDuration: TimeInterval {
        max(duration, player?.duration ?? 0)
    }

    private var progress: Double {
        guard displayDuration > 0 else { return 0 }
        return min(max(elapsed / displayDuration, 0), 1)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause audio message" : "Play audio message")
            .disabled(loadError != nil)

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { proxy in
                    WaveformStrip(samples: waveform, progress: progress)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    scrub(toX: value.location.x, width: proxy.size.width)
                                }
                        )
                        .accessibilityLabel("Audio waveform")
                }
                .frame(height: 28)

                HStack {
                    Text(formatted(elapsed))
                    Spacer()
                    Text(formatted(displayDuration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 280)
        .background(role == .user ? Color.white.opacity(0.18) : Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            preparePlayerIfNeeded()
        }
        .task(id: isPlaying) {
            guard isPlaying else { return }
            while !Task.isCancelled, isPlaying {
                refreshPlaybackState()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        .onDisappear {
            player?.stop()
            isPlaying = false
        }
    }

    private func preparePlayerIfNeeded() {
        guard player == nil, loadError == nil else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = "Audio unavailable"
            return
        }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            elapsed = min(elapsed, displayDuration)
        } catch {
            loadError = "Audio unavailable"
        }
    }

    private func togglePlayback() {
        preparePlayerIfNeeded()
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if elapsed >= displayDuration {
                player.currentTime = 0
                elapsed = 0
            }
            player.play()
            isPlaying = true
        }
    }

    private func refreshPlaybackState() {
        guard let player else { return }
        elapsed = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            if elapsed >= displayDuration - 0.05 {
                elapsed = displayDuration
            }
        }
    }

    private func scrub(toX x: CGFloat, width: CGFloat) {
        guard displayDuration > 0, width > 0 else { return }
        let ratio = min(max(Double(x / width), 0), 1)
        let target = displayDuration * ratio
        elapsed = target
        player?.currentTime = target
    }

    private func formatted(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "0:00" }
        let totalSeconds = max(Int(value.rounded()), 0)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

private struct WaveformStrip: View {
    let samples: [Float]?
    let progress: Double

    private var bars: [Float] {
        let source: [Float]
        if let samples, !samples.isEmpty {
            source = samples
        } else {
            source = Array(repeating: 0.35, count: 32)
        }
        guard source.count > 48 else { return source }
        let bucketSize = Double(source.count) / 48.0
        return (0..<48).map { index in
            let start = Int(Double(index) * bucketSize)
            let end = min(Int(Double(index + 1) * bucketSize), source.count)
            guard start < end else { return 0 }
            return source[start..<end].map { abs($0) }.max() ?? 0
        }
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, sample in
                    Capsule()
                        .fill(Double(index) / Double(max(bars.count - 1, 1)) <= progress ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: barWidth(in: proxy.size.width), height: barHeight(sample, maxHeight: proxy.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func barWidth(in width: CGFloat) -> CGFloat {
        max((width - CGFloat(max(bars.count - 1, 0)) * 2) / CGFloat(max(bars.count, 1)), 2)
    }

    private func barHeight(_ sample: Float, maxHeight: CGFloat) -> CGFloat {
        let normalized = min(max(CGFloat(abs(sample)), 0), 1)
        return max(4, maxHeight * (0.2 + normalized * 0.8))
    }
}

#Preview {
    AudioMessageView(
        url: URL(fileURLWithPath: "/Users/example/Library/Containers/app/audio.m4a"),
        duration: 42,
        waveform: [0.1, 0.4, 0.8, 0.3, 0.6, 0.2],
        role: .assistant
    )
}
