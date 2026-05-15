import Foundation
import ManifoldInference

/// Applies a sequence of ``HistoryProvider``s to a base history array,
/// inserting each provider's contributions at their declared positions.
///
/// Providers are applied in order; each sees the output of the previous one.
/// The output is validated in debug builds to ensure `.chat`-kind user/assistant
/// chronological order is preserved.
struct HistoryAssembler: Sendable {
    private let providers: [any HistoryProvider]

    init(providers: [any HistoryProvider]) {
        self.providers = providers
    }

    func assemble(
        history: [ChatMessageRecord],
        context: TurnContext
    ) async throws -> [ChatMessageRecord] {
        var current = history
        for provider in providers {
            let contributions = try await provider.contribute(history: current, context: context)
            current = apply(contributions, to: current)
        }
        assertChronologicalOrder(current)
        return current
    }

    // MARK: - Insertion

    private func apply(
        _ contributions: [HistoryContribution],
        to history: [ChatMessageRecord]
    ) -> [ChatMessageRecord] {
        var result = history
        // Process contributions in reverse depth order so earlier insertions
        // don't shift indices used by later ones in the same batch.
        let sorted = contributions.sorted { lhs, rhs in
            insertionIndex(for: lhs.position, in: result) >= insertionIndex(for: rhs.position, in: result)
        }
        for contribution in sorted {
            let idx = insertionIndex(for: contribution.position, in: result)
            result.insert(contribution.record, at: idx)
        }
        return result
    }

    private func insertionIndex(
        for position: HistoryInsertionPosition,
        in history: [ChatMessageRecord]
    ) -> Int {
        switch position {
        case .head:
            return 0
        case .tail:
            return history.endIndex
        case .atDepth(let n):
            let clamped = max(0, min(n, history.count))
            return history.endIndex - clamped
        case .beforeRecord(let id):
            return history.firstIndex(where: { $0.id == id }) ?? history.endIndex
        case .afterRecord(let id):
            guard let idx = history.firstIndex(where: { $0.id == id }) else { return history.endIndex }
            return history.index(after: idx)
        }
    }

    // MARK: - Invariant check

    private func assertChronologicalOrder(_ history: [ChatMessageRecord]) {
        #if DEBUG
        let chatRecords = history.filter { $0.kind == .chat && ($0.role == .user || $0.role == .assistant) }
        for i in 1 ..< chatRecords.count {
            assert(
                chatRecords[i].timestamp >= chatRecords[i - 1].timestamp,
                "HistoryAssembler: chronological order of .chat user/assistant records violated after provider application. " +
                "Record \(chatRecords[i].id) (\(chatRecords[i].timestamp)) is older than \(chatRecords[i-1].id) (\(chatRecords[i-1].timestamp))."
            )
        }
        #endif
    }
}
