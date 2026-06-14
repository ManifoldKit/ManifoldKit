import SwiftUI
import ManifoldHardware
import ManifoldRuntime
import ManifoldInference
import ManifoldUI

// `ModelSelectionSortOrder` and the grouping/sorting seam live on
// `ModelSelection` in ManifoldInference (hoisted so headless consumers can sort
// and group the list as data). Imported above.

/// A thin, styleable **sample** model selector over ``ModelSelection``.
///
/// The headless ``ModelSelection`` type is the product: it vends the sorted /
/// scored / grouped model list as data and owns the synchronous load path. A
/// consumer is expected to render their own selector over that data —
/// `ModelPicker` is the **default**, not the only path. It is the view formerly
/// known as `ModelSelectionTabView`, promoted to a public sample so apps can
/// drop in a working selector or read its source as a worked example.
///
/// `ModelPicker` reads selection state from a ``ModelRegistry`` (so selecting in
/// the picker is visible to any sibling `ChatViewModel` over the same registry)
/// and renders rows from ``ModelSelection``'s shared sorting (``ModelSelection/sortModels(_:by:)``)
/// and grouping (``ModelSelection/groupModels(_:by:)``) helpers. Set
/// ``grouped`` to render the Apple-Foundation-vs-downloaded sections; leave it
/// `false` for a single flat list (the historical `ModelSelectionTabView`
/// layout).
///
/// For the headless selection + load path behind this view — the real product
/// — see the "Choosing and Loading Models (Headless)" guide
/// (`docs/QUICKSTART-MODEL-SELECTION.md`) and ``ModelSelection``.
public struct ModelPicker: View {

    /// Two-way binding into the registry: the picker reads
    /// ``ModelRegistry/selectedModel`` and writes the user's tap back.
    @Bindable private var modelRegistry: ModelRegistry

    /// When `true`, models render in Apple-Foundation / downloaded sections
    /// (``ModelSelection/groupModels(_:by:)``). When `false` (the default), a
    /// single flat sorted list renders — the historical `ModelSelectionTabView`
    /// layout the bundled sheet relies on.
    private let grouped: Bool

    @State private var sortOrder: ModelSelectionSortOrder = .alphabetical

    /// Invoked after a model row is tapped (the selection has already been
    /// written back to the registry). Hosts typically dismiss a presenting
    /// sheet here.
    let onSelect: () -> Void

    /// Builds a picker over a registry the host already constructed (typically
    /// `chatViewModel.modelRegistry`).
    ///
    /// - Parameters:
    ///   - modelRegistry: The selection-state source. Selecting in the picker
    ///     writes back here, so any sibling surface over the same registry sees
    ///     the change.
    ///   - grouped: Render foundation / downloaded sections (`true`) or a single
    ///     flat list (`false`, the default — the historical layout).
    ///   - onSelect: Called after a tap, once the selection is committed.
    public init(
        modelRegistry: ModelRegistry,
        grouped: Bool = false,
        onSelect: @escaping () -> Void
    ) {
        self._modelRegistry = Bindable(modelRegistry)
        self.grouped = grouped
        self.onSelect = onSelect
    }

    /// The flat, sorted list (used when ``grouped`` is `false`).
    var sortedModels: [ModelInfo] {
        ModelSelection.sortModels(modelRegistry.availableModels, by: sortOrder)
    }

    /// The grouped sections (used when ``grouped`` is `true`).
    var groupedModels: [(group: ModelSelectionGroup, models: [ModelInfo])] {
        ModelSelection.groupModels(modelRegistry.availableModels, by: sortOrder)
    }

    public var body: some View {
        List {
            if modelRegistry.availableModels.isEmpty {
                emptyState
            } else if grouped {
                sortControl
                ForEach(Array(groupedModels.enumerated()), id: \.element.group) { index, section in
                    Section {
                        rows(for: section.models)
                    } header: {
                        Text(section.group.title)
                    } footer: {
                        // Attach the load/endpoint caveat to the last section so
                        // it reads as a single trailing note rather than once
                        // per group.
                        if index == groupedModels.count - 1 {
                            Text("Selecting a model loads it into memory and clears any active cloud API endpoint.")
                                .font(.caption)
                        }
                    }
                }
            } else {
                Section {
                    sortControl
                    rows(for: sortedModels)
                } footer: {
                    Text("Selecting a model loads it into memory and clears any active cloud API endpoint.")
                        .font(.caption)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.plain)
        #endif
        .accessibilityLabel("Available models")
    }

    @ViewBuilder
    private var sortControl: some View {
        Picker("Sort by", selection: $sortOrder) {
            ForEach(ModelSelectionSortOrder.allCases) { order in
                Text(order.rawValue).tag(order)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("model-selection-sort-picker")
    }

    @ViewBuilder
    private func rows(for models: [ModelInfo]) -> some View {
        ForEach(models) { model in
            ModelSelectionRow(
                model: model,
                isSelected: modelRegistry.selectedModel?.id == model.id,
                compatibilityResult: modelRegistry.compatibility(for: model.modelType)
            ) {
                modelRegistry.selectedModel = model
                onSelect()
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        #if os(macOS)
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No Models Available")
                    .font(.headline)
                Text("Download a model from the Download tab to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            Spacer()
        }
        .listRowBackground(Color.clear)
        #else
        ContentUnavailableView(
            "No Models Available",
            systemImage: "cpu",
            description: Text("Download a model from the Download tab to get started.")
        )
        .listRowBackground(Color.clear)
        #endif
    }
}

private struct ModelSelectionRow: View {

    let model: ModelInfo
    let isSelected: Bool
    let compatibilityResult: ModelCompatibilityResult
    let onTap: () -> Void

    private var isCompatible: Bool { compatibilityResult.isSupported }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        isCompatible
                        ? (isSelected ? Color.accentColor : .secondary)
                        : Color.secondary.opacity(0.4)
                    )
                    .imageScale(.large)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name)
                        .font(.body)
                        .foregroundStyle(isCompatible ? .primary : .secondary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        typeBadge(for: model.modelType, isCompatible: isCompatible)

                        if model.modelType != .foundation {
                            Text(model.fileSizeFormatted)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        tierBadge(for: model.effectiveCapabilityTier)
                    }

                    if let reason = compatibilityResult.unavailableReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.top, 1)
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isCompatible)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isCompatible ? "" : (compatibilityResult.unavailableReason ?? "Backend not available"))
    }

    private var accessibilityLabel: String {
        let type: String
        switch model.modelType {
        case .gguf: type = "GGUF"
        case .mlx: type = "MLX"
        case .foundation: type = "Apple Foundation Model"
        }
        let tier = model.effectiveCapabilityTier.label
        if model.modelType == .foundation {
            return "\(model.name), \(type), \(tier)"
        }
        return "\(model.name), \(type), \(model.fileSizeFormatted), \(tier)"
    }

    @ViewBuilder
    private func typeBadge(for modelType: ModelType, isCompatible: Bool) -> some View {
        let (label, color): (String, Color) = {
            switch modelType {
            case .gguf: return ("GGUF", .orange)
            case .mlx: return ("MLX", .purple)
            case .foundation: return ("Foundation", .blue)
            }
        }()

        Text(label)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(isCompatible ? color : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (isCompatible ? color : Color.secondary).opacity(0.12),
                in: Capsule()
            )
    }

    @ViewBuilder
    private func tierBadge(for tier: ModelCapabilityTier) -> some View {
        Text(tier.label)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.fill.secondary, in: Capsule())
    }
}
