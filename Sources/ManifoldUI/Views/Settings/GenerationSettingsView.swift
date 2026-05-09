import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// A settings sheet for configuring generation parameters.
///
/// Presented as a `.sheet` from the chat toolbar. Shows a basic section
/// (temperature, system prompt, appearance) always visible, and an advanced
/// section (top-p, repeat penalty, prompt template, presets, backend info,
/// cloud APIs) hidden behind a `DisclosureGroup` that is collapsed by default.
/// The disclosure state is persisted via `@AppStorage` so power users who
/// expand it once keep it expanded.
public struct GenerationSettingsView<APIConfig: View>: View {

    @Environment(ChatViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    private var features: ManifoldConfiguration.Features { ManifoldConfiguration.shared.features }
    private var compiledBackends: CompiledBackends { .current }

    @AppStorage("showAdvancedSettings") private var showAdvancedSettings = false
    @State private var isAPIConfigPresented = false
    @State private var isPromptInspectorPresented = false

    /// Builder for the API configuration view shown from the "Manage Cloud APIs"
    /// row. Closure-injected so this view stays free of any back-edge to the
    /// `ManifoldUIModelManagement` module that owns `APIConfigurationView`.
    private let apiConfigurationBuilder: () -> APIConfig

    public init(@ViewBuilder apiConfiguration: @escaping () -> APIConfig) {
        self.apiConfigurationBuilder = apiConfiguration
    }

    public var body: some View {
        @Bindable var viewModel = viewModel

        let capabilities = viewModel.backendCapabilities

        NavigationStack {
            Form {
                // MARK: Basic — Temperature
                Section("Sampling") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Text(String(format: "%.2f", viewModel.temperature))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $viewModel.temperature, in: 0.0...2.0, step: 0.1)
                            .disabled(capabilities?.supportedParameters.contains(.temperature) == false)
                            .accessibilityLabel("Temperature")
                            .accessibilityValue(String(format: "%.2f", viewModel.temperature))
                    }
                }

                // MARK: Basic — System Prompt
                Section("System Prompt") {
                    ZStack(alignment: .topLeading) {
                        if viewModel.systemPrompt.isEmpty {
                            Text("Optional system instructions...")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        TextEditor(text: $viewModel.systemPrompt)
                            .frame(minHeight: 80)
                            .accessibilityLabel("System prompt")
                    }
                }

                // MARK: Basic — Appearance
                Section("Appearance") {
                    Picker("Color Scheme", selection: Binding(
                        get: { SettingsService.shared.appearanceMode },
                        set: { SettingsService.shared.appearanceMode = $0 }
                    )) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // MARK: Basic — Reset
                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        let settings = SettingsService.shared
                        viewModel.temperature = settings.globalTemperature ?? 0.7
                        viewModel.topP = settings.globalTopP ?? 0.9
                        viewModel.repeatPenalty = settings.globalRepeatPenalty ?? 1.1
                    }
                }

                // MARK: Advanced (collapsed by default)
                if features.showAdvancedSettings {
                Section {
                    DisclosureGroup(isExpanded: $showAdvancedSettings) {
                        // Top P
                        if capabilities?.supportedParameters.contains(.topP) == true {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Top P")
                                    Spacer()
                                    Text(String(format: "%.2f", viewModel.topP))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $viewModel.topP, in: 0.0...1.0, step: 0.05)
                                    .accessibilityLabel("Top P")
                                    .accessibilityValue(String(format: "%.2f", viewModel.topP))
                            }
                            .padding(.vertical, 2)
                        }

                        // Repeat Penalty
                        if capabilities?.supportedParameters.contains(.repeatPenalty) == true {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Repeat Penalty")
                                    Spacer()
                                    Text(String(format: "%.2f", viewModel.repeatPenalty))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $viewModel.repeatPenalty, in: 1.0...2.0, step: 0.05)
                                    .accessibilityLabel("Repeat Penalty")
                                    .accessibilityValue(String(format: "%.2f", viewModel.repeatPenalty))
                            }
                            .padding(.vertical, 2)
                        }

                        // Prompt Template
                        if capabilities?.requiresPromptTemplate == true {
                            Picker("Prompt Template", selection: $viewModel.selectedPromptTemplate) {
                                ForEach(PromptTemplate.allCases) { template in
                                    Text(template.rawValue).tag(template)
                                }
                            }
                        }
                    } label: {
                        Text("Advanced Settings")
                            .font(.headline)
                    }
                    .accessibilityIdentifier("advanced-settings-disclosure")
                }

                // Sampler Presets — inside advanced, rendered as its own Section
                if showAdvancedSettings {
                    SamplerPresetPickerView()
                }

                // Backend Info — inside advanced
                if showAdvancedSettings {
                    Section("Backend") {
                        LabeledContent("Type") {
                            Text(viewModel.activeBackendName ?? "None")
                                .foregroundStyle(viewModel.activeBackendName != nil ? .primary : .secondary)
                        }

                        if let capabilities {
                            LabeledContent("Max Context") {
                                Text("\(capabilities.maxContextTokens) tokens")
                            }
                        }
                    }

                    if features.showCloudAPIManagement && compiledBackends.shouldPresentCloudAPIManagement {
                        Section("Cloud APIs") {
                            Button {
                                isAPIConfigPresented = true
                            } label: {
                                Label("Manage Cloud APIs", systemImage: "cloud")
                            }
                        }
                    }

                    Section("Debug") {
                        Button {
                            isPromptInspectorPresented = true
                        } label: {
                            Label("Prompt Inspector", systemImage: "doc.text.magnifyingglass")
                        }
                        .accessibilityLabel("Open prompt inspector")
                    }
                }
                } // end features.showAdvancedSettings
            }
            .formStyle(.grouped)
            .navigationTitle("Generation Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task {
                            do {
                                try await viewModel.saveSettingsToSession()
                            } catch {
                                Log.persistence.error("Failed to save settings from sheet: \(error)")
                                viewModel.errorMessage = "Failed to save settings: \(error.localizedDescription)"
                            }
                        }
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isAPIConfigPresented) {
                apiConfigurationBuilder()
            }
            .sheet(isPresented: $isPromptInspectorPresented) {
                PromptInspectorView(
                    assembledPrompt: nil,
                    contextSize: viewModel.contextMaxTokens
                )
            }
        }
    }
}

// MARK: - Preview

#Preview("Generation Settings") {
    GenerationSettingsView { EmptyView() }
        .environment(ChatViewModel())
}
