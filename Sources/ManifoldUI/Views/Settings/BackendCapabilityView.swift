import SwiftUI
import ManifoldInference

// MARK: - BackendCapabilityView

/// P5c: Backend capability matrix and incognito persistence switch.
///
/// Displays the active backend's ``BackendCapabilities`` as a form with
/// boolean checkmarks and integer/string values. When the host app provides
/// an `onRequestIncognitoMode` closure, an Incognito toggle appears that the
/// host wires to an in-memory persistence rebuild.
struct BackendCapabilityView: View {

    @Environment(\.manifoldTheme) private var theme

    let capabilities: BackendCapabilities?
    /// Optional closure called when the user enables Incognito mode.
    /// When `nil`, the Incognito toggle is hidden.
    var onRequestIncognitoMode: (() -> Void)?

    @State private var incognitoEnabled: Bool = false

    var body: some View {
        Group {
            if let cap = capabilities {
                capabilityForm(cap)
            } else {
                noBackendView
            }
        }
        .accessibilityIdentifier("architect-backend-tab")
    }

    // MARK: - No Backend

    private var noBackendView: some View {
        ContentUnavailableView {
            Label("No Backend Loaded", systemImage: "cpu.fill")
        } description: {
            Text("Load a model to inspect backend capabilities.")
        }
    }

    // MARK: - Capability Form

    private func capabilityForm(_ cap: BackendCapabilities) -> some View {
        Form {
            Section("Context & Output") {
                LabeledContent("Max Context Tokens") {
                    Text("\(cap.maxContextTokens)")
                        .monospacedDigit()
                }
                .accessibilityLabel("Max context tokens: \(cap.maxContextTokens)")

                LabeledContent("Max Output Tokens") {
                    Text("\(cap.maxOutputTokens)")
                        .monospacedDigit()
                }
                .accessibilityLabel("Max output tokens: \(cap.maxOutputTokens)")
            }

            Section("Capabilities") {
                capabilityRow("Streaming", value: cap.supportsStreaming)
                capabilityRow("Tool Calling", value: cap.supportsToolCalling)
                capabilityRow("Parallel Tool Calls", value: cap.supportsParallelToolCalls)
                capabilityRow("Structured Output", value: cap.supportsStructuredOutput)
                capabilityRow("Native JSON Mode", value: cap.supportsNativeJSONMode)
                capabilityRow("Grammar Constrained Sampling", value: cap.supportsGrammarConstrainedSampling)
                capabilityRow("Guided Structured Output", value: cap.supportsGuidedStructuredOutput)
                capabilityRow("Thinking", value: cap.supportsThinking)
                capabilityRow("Vision", value: cap.supportsVision)
                capabilityRow("System Prompt", value: cap.supportsSystemPrompt)
                capabilityRow("Token Counting", value: cap.supportsTokenCounting)
                capabilityRow("KV Cache Persistence", value: cap.supportsKVCachePersistence)
                capabilityRow("Streams Tool Call Arguments", value: cap.streamsToolCallArguments)
            }

            Section("Runtime") {
                LabeledContent("Memory Strategy") {
                    Text(cap.memoryStrategy.rawValue)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Memory strategy: \(cap.memoryStrategy.rawValue)")

                LabeledContent("Cancellation Style") {
                    Text(cap.cancellationStyle.rawValue)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Cancellation style: \(cap.cancellationStyle.rawValue)")

                capabilityRow("Remote", value: cap.isRemote)
                capabilityRow("Requires Prompt Template", value: cap.requiresPromptTemplate)
                capabilityRow("Shares MLX Process Resources", value: cap.sharesMLXProcessResources)

                if let maxTools = cap.maxAdvertisedToolCount {
                    LabeledContent("Max Advertised Tools") {
                        Text("\(maxTools)")
                            .monospacedDigit()
                    }
                    .accessibilityLabel("Max advertised tool count: \(maxTools)")
                }
            }

            Section("Sampling Parameters") {
                if cap.supportedParameters.isEmpty {
                    Text("No sampling parameters reported.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(cap.visibleParameters, id: \.rawValue) { param in
                        Label(param.rawValue, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(theme.statusOK)
                            .font(.callout)
                            .accessibilityLabel("\(param.rawValue) supported")
                    }
                }
            }

            if onRequestIncognitoMode != nil {
                incognitoSection
            }
        }
    }

    // MARK: - Incognito Section

    private var incognitoSection: some View {
        Section {
            Toggle(isOn: $incognitoEnabled) {
                Label("Incognito Mode", systemImage: "eye.slash")
            }
            .onChange(of: incognitoEnabled) { _, newValue in
                if newValue {
                    onRequestIncognitoMode?()
                }
            }
            .accessibilityLabel("Incognito mode toggle")
            .accessibilityHint("When enabled, conversation history is stored in memory only and not persisted")

            if incognitoEnabled {
                Label("History is stored in memory only and will not be saved.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Incognito mode switches to an in-memory message store. Reopen the session to restore normal persistence.")
        }
    }

    // MARK: - Helpers

    private func capabilityRow(_ label: String, value: Bool) -> some View {
        HStack {
            Text(label)
                .font(.callout)
            Spacer()
            Image(systemName: value ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(value ? theme.statusOK : theme.ink2)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value ? "supported" : "not supported")")
    }
}
