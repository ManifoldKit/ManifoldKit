import Foundation
import ManifoldInference

// Phase-boundary value types shared by turn preparation and the executor.
// Preparation / finalization live in ``TurnPreparation`` and
// ``TurnStreamFinalizer``; this file holds the small history-prep result
// type both the executor and direct unit tests consume.

/// Output of the pre-assembly history-preparation phase. Carries the prompt-
/// visible history after host shaping + additive history providers plus the
/// resolved turn context snapshot used by downstream prompt assembly and
/// post-generation hooks.
///
/// `package` so ``TurnPreparation/prepareHistory`` can surface it across the
/// package boundary used by direct unit tests (#1957 Priority 3).
package struct PreparedTurnHistory: Sendable {
    package var history: [ChatMessage]
    package var turnContext: TurnContext

    package init(history: [ChatMessage], turnContext: TurnContext) {
        self.history = history
        self.turnContext = turnContext
    }
}
