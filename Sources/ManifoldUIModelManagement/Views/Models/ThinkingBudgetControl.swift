import SwiftUI
import ManifoldInference
import ManifoldUI

/// The three-way thinking-budget lever (spec §5 rule 4, `docs/UI-REFRESH-2026.md`,
/// issue #2307 Unit 2 §L3): **there is no "reasoning effort" enum** — the
/// underlying knob is `GenerationConfig.maxThinkingTokens`.
///
/// | Option | `maxThinkingTokens` |
/// |---|---|
/// | ``off`` | `0` |
/// | ``auto`` | `nil` |
/// | ``extended`` | a named token budget, supplied by the caller |
package enum ThinkingBudgetOption: String, CaseIterable, Sendable, Identifiable {
    case off
    case auto
    case extended

    package var id: String { rawValue }

    package var label: String {
        switch self {
        case .off: return "Off"
        case .auto: return "Auto"
        case .extended: return "Extended"
        }
    }

    /// Resolves this option to the `GenerationConfig.maxThinkingTokens` value
    /// it represents. `extendedBudget` is the caller's named budget for
    /// ``extended`` (e.g. a model-specific token ceiling).
    package func maxThinkingTokens(extendedBudget: Int) -> Int? {
        switch self {
        case .off: return 0
        case .auto: return nil
        case .extended: return extendedBudget
        }
    }

    /// Inverse of ``maxThinkingTokens(extendedBudget:)`` — resolves a stored
    /// `GenerationConfig.maxThinkingTokens` value back to the option a
    /// segmented control should highlight. A stored value that matches
    /// neither `0` nor `extendedBudget` (e.g. a budget from a different model)
    /// falls back to ``auto`` rather than silently picking the nearest option.
    package static func resolved(maxThinkingTokens: Int?, extendedBudget: Int) -> ThinkingBudgetOption {
        switch maxThinkingTokens {
        case .some(0):
            return .off
        case .some(let value) where value == extendedBudget:
            return .extended
        case .none:
            return .auto
        default:
            return .auto
        }
    }
}

/// Renders the thinking-budget picker, but only when the loaded model
/// actually emits reasoning tokens — ``ModelManifest/supportsThinking``.
/// Showing this control for a non-thinking model would offer a lever the
/// backend can't honor (spec §5 rule 4's "never show a control the backend
/// won't honor," which also governs sampler-knob visibility via
/// `ModelManifest.supportedSamplingParameters`).
package struct ThinkingBudgetControl: View {
    package let manifest: ModelManifest
    package let extendedBudget: Int
    @Binding package var maxThinkingTokens: Int?

    package init(
        manifest: ModelManifest,
        maxThinkingTokens: Binding<Int?>,
        extendedBudget: Int = 8192
    ) {
        self.manifest = manifest
        self._maxThinkingTokens = maxThinkingTokens
        self.extendedBudget = extendedBudget
    }

    private var selection: Binding<ThinkingBudgetOption> {
        Binding(
            get: { ThinkingBudgetOption.resolved(maxThinkingTokens: maxThinkingTokens, extendedBudget: extendedBudget) },
            set: { maxThinkingTokens = $0.maxThinkingTokens(extendedBudget: extendedBudget) }
        )
    }

    package var body: some View {
        if manifest.supportsThinking {
            Picker("Thinking", selection: selection) {
                ForEach(ThinkingBudgetOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Thinking budget")
        }
    }
}
