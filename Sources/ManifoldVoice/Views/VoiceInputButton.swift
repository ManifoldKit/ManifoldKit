import SwiftUI

public struct VoiceInputButton: View {
    private let isRecording: Bool
    private let isBusy: Bool
    private let action: () -> Void

    public init(
        isRecording: Bool,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) {
        self.isRecording = isRecording
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(buttonTitle, systemImage: systemImage)
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecording ? .red : .accentColor)
        .disabled(isBusy)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("voice-input-button")
    }

    private var buttonTitle: String {
        if isBusy { return "Finishing…" }
        return isRecording ? "Stop" : "Voice"
    }

    private var systemImage: String {
        if isBusy { return "waveform.badge.magnifyingglass" }
        return isRecording ? "stop.circle.fill" : "mic.circle.fill"
    }

    private var accessibilityLabel: String {
        if isBusy { return "Finishing voice capture" }
        return isRecording ? "Stop voice capture" : "Start voice capture"
    }

    private var accessibilityHint: String {
        if isBusy { return "Wait for the speech recognizer to finish transcribing." }
        return isRecording
            ? "Stops recording and keeps the transcript in the draft."
            : "Starts dictating a chat draft from your microphone."
    }
}
