import SwiftUI
import BaseChatRuntime
import BaseChatInference
import BaseChatUI

enum ModelSelectionSortOrder: String, CaseIterable, Identifiable {
    case alphabetical = "Alphabetical"
    case type = "Type"
    case size = "Size (Smallest First)"
    case capability = "Capability / Speed"

    var id: Self { self }
}

/// Inline model selection content used by `ModelManagementSheet`.
struct ModelSelectionTabView: View {

    @Environment(ChatViewModel.self) private var chatViewModel
    @State private var sortOrder: ModelSelectionSortOrder = .alphabetical

    let onSelect: () -> Void

    var sortedModels: [ModelInfo] {
        Self.sortModels(chatViewModel.availableModels, by: sortOrder)
    }

    var body: some View {
        List {
            if chatViewModel.availableModels.isEmpty {
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
            } else {
                Section {
                    Picker("Sort by", selection: $sortOrder) {
                        ForEach(ModelSelectionSortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("model-selection-sort-picker")

                    ForEach(sortedModels) { model in
                        ModelSelectionRow(
                            model: model,
                            isSelected: chatViewModel.selectedModel?.id == model.id
                        ) {
                            chatViewModel.selectedModel = model
                            onSelect()
                        }
                    }
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

    static func sortModels(_ models: [ModelInfo], by order: ModelSelectionSortOrder) -> [ModelInfo] {
        models.sorted { lhs, rhs in
            switch order {
            case .alphabetical:
                return compareNames(lhs, rhs)

            case .type:
                let lhsKey = (typeSortRank(for: lhs.modelType), lhs.name)
                let rhsKey = (typeSortRank(for: rhs.modelType), rhs.name)
                if lhsKey.0 != rhsKey.0 {
                    return lhsKey.0 < rhsKey.0
                }
                return lhsKey.1.localizedStandardCompare(rhsKey.1) == .orderedAscending

            case .size:
                if lhs.fileSize != rhs.fileSize {
                    return lhs.fileSize < rhs.fileSize
                }
                return compareNames(lhs, rhs)

            case .capability:
                let lhsTier = lhs.effectiveCapabilityTier.rawValue
                let rhsTier = rhs.effectiveCapabilityTier.rawValue
                if lhsTier != rhsTier {
                    return lhsTier > rhsTier
                }
                if lhs.fileSize != rhs.fileSize {
                    return lhs.fileSize < rhs.fileSize
                }
                return compareNames(lhs, rhs)
            }
        }
    }

    private static func compareNames(_ lhs: ModelInfo, _ rhs: ModelInfo) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func typeSortRank(for type: ModelType) -> Int {
        switch type {
        case .foundation: return 0
        case .gguf: return 1
        case .mlx: return 2
        }
    }
}

private struct ModelSelectionRow: View {

    @Environment(ChatViewModel.self) private var chatViewModel

    let model: ModelInfo
    let isSelected: Bool
    let onTap: () -> Void

    private var compatibilityResult: ModelCompatibilityResult {
        chatViewModel.inferenceService.compatibility(for: model.modelType)
    }

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
