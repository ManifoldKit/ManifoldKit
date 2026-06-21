import SwiftUI
import ManifoldUI

public enum VoiceDraftMergeStrategy: Sendable {
    case replace
    case append
}

enum VoiceDraftComposer {
    static func merge(transcript: String, into draft: String, strategy: VoiceDraftMergeStrategy) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return draft }

        switch strategy {
        case .replace:
            return trimmedTranscript
        case .append:
            let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDraft.isEmpty else { return trimmedTranscript }
            return "\(trimmedDraft)\n\(trimmedTranscript)"
        }
    }
}

public struct VoiceComposerAccessory: View {
    @Environment(ChatViewModel.self) private var viewModel

    private let controller: VoiceConversationController
    private let mergeStrategy: VoiceDraftMergeStrategy

    public init(
        controller: VoiceConversationController,
        mergeStrategy: VoiceDraftMergeStrategy = .append
    ) {
        self.controller = controller
        self.mergeStrategy = mergeStrategy
    }

    public var body: some View {
        @Bindable var controller = controller

        VStack(alignment: .leading, spacing: 8) {
            if controller.showsTranscriptPreview {
                LiveTranscriptionView(
                    text: transcriptPreviewText(for: controller),
                    title: controller.captureState == .processing ? "Finishing transcript…" : "Voice draft"
                )
            }

            HStack(spacing: 12) {
                VoiceInputButton(
                    isRecording: controller.isRecording,
                    isBusy: controller.captureState == .processing
                ) {
                    Task {
                        await handleVoiceInputTapped()
                    }
                }

                if let latestAssistantReply {
                    Button {
                        controller.togglePlayback(for: latestAssistantReply)
                    } label: {
                        Label(
                            controller.isSpeaking ? "Stop Reading" : "Read Last Reply",
                            systemImage: controller.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.captureState == .recording || controller.captureState == .processing)
                    .accessibilityLabel(
                        controller.isSpeaking ? "Stop reading the last assistant reply aloud" : "Read the last assistant reply aloud"
                    )
                    .accessibilityIdentifier("voice-playback-button")
                }

                if let status = controller.statusText {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(isFailure(controller.captureState) ? Color.red : .secondary)
                        .lineLimit(2)
                }

                if controller.recoveryAffordance == .openSettings {
                    Button("Open Settings") {
                        controller.openSystemSettings()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .accessibilityHint("Opens system settings so you can grant microphone and speech access.")
                    .accessibilityIdentifier("voice-open-settings-button")
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(.bar)
        .onDisappear {
            controller.cancelRecording()
            controller.stopSpeaking()
        }
    }

    private var latestAssistantReply: String? {
        let latestMessage = viewModel.messages.last {
            $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return latestMessage?.content
    }

    private func transcriptPreviewText(for controller: VoiceConversationController) -> String {
        let trimmed = controller.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        switch controller.captureState {
        case .recording:
            return "Start speaking to dictate your next draft."
        case .processing:
            return "Waiting for the final on-device transcript…"
        case .idle, .requestingPermission, .failed:
            return ""
        }
    }

    private func handleVoiceInputTapped() async {
        if controller.isRecording {
            guard let transcript = await controller.stopRecording() else { return }
            viewModel.inputText = VoiceDraftComposer.merge(
                transcript: transcript,
                into: viewModel.inputText,
                strategy: mergeStrategy
            )
        } else {
            await controller.startRecording()
        }
    }

    private func isFailure(_ state: VoiceCaptureState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
