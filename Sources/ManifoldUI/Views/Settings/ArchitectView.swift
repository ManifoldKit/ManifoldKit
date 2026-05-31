import SwiftUI
import ManifoldRuntime
import ManifoldInference

// MARK: - ArchitectView

/// Developer-facing inspector sheet that makes ManifoldKit internals observable
/// in real time.
///
/// ## Tabs
///
/// - **Timeline** (P5a): Live event log draining from the runtime's event tap.
///   Each row shows the event kind in monospace, a short summary of associated
///   values, and a colour-coded category dot. Compression events are visually
///   distinct with an orange tint and badge.
///
/// - **Context** (P5b): Slot inspector showing the most recent
///   `.contextAssembled` event's slots and a token budget bar. A compression
///   history table lists all `.historyCompressed` events.
///
/// - **Backend** (P5c): Capability matrix for the active backend, plus an
///   optional Incognito mode toggle wired via ``onRequestIncognitoMode``.
///
/// ## Integration
///
/// ```swift
/// .sheet(isPresented: $showArchitectView) {
///     ArchitectView(
///         runtime: viewModel.runtime,
///         capabilities: viewModel.backendCapabilities
///     )
/// }
/// ```
///
/// The `onRequestIncognitoMode` closure is optional. When set, a toggle
/// in the Backend tab calls it; the host app is responsible for rebuilding
/// persistence with an in-memory store. This decouples the inspector from
/// any specific persistence implementation.
public struct ArchitectView: View {

    @State private var viewModel: ArchitectViewModel
    @State private var selectedTab: ArchitectTab = .timeline
    @Environment(\.dismiss) private var dismiss

    private let capabilities: BackendCapabilities?
    /// Optional closure called when the user enables Incognito mode.
    public var onRequestIncognitoMode: (() -> Void)?

    // MARK: - Init

    public init(
        runtime: ConversationRuntime,
        capabilities: BackendCapabilities? = nil
    ) {
        _viewModel = State(initialValue: ArchitectViewModel(runtime: runtime))
        self.capabilities = capabilities
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tab", selection: $selectedTab) {
                    ForEach(ArchitectTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                tabContent
            }
            .navigationTitle("Architect")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(viewModel.isRecording ? "Pause" : "Record") {
                        if viewModel.isRecording {
                            viewModel.stopRecording()
                        } else {
                            viewModel.startRecording()
                        }
                    }
                    .foregroundStyle(viewModel.isRecording ? .orange : .accentColor)
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear") { viewModel.clearLog() }
                        .disabled(viewModel.eventLog.isEmpty)
                }
            }
            .onAppear { viewModel.startRecording() }
            .onDisappear { viewModel.stopRecording() }
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .timeline:
            EventTimelineView(viewModel: viewModel)
        case .context:
            ContextSlotInspectorView(viewModel: viewModel)
        case .backend:
            BackendCapabilityView(
                capabilities: capabilities,
                onRequestIncognitoMode: onRequestIncognitoMode
            )
        }
    }

    // MARK: - Tab enum

    enum ArchitectTab: String, CaseIterable {
        case timeline = "Timeline"
        case context = "Context"
        case backend = "Backend"
    }
}
