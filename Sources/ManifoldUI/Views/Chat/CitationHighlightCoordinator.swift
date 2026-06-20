import SwiftUI
import ManifoldInference

/// Per-bubble transient state that links an inline `[n]` marker tap to the matching
/// source card in ``CitationsView``.
///
/// When the user taps a superscript marker, the bubble sets ``target`` to the
/// citation's 0-based index. ``CitationsView`` observes this to (a) expand its
/// disclosure, (b) scroll the row into view, and (c) flash a transient highlight.
/// The highlight auto-clears after a short delay so re-tapping the same marker
/// re-triggers it.
///
/// Scoped to a single bubble (one instance per ``MessageBubbleView``) so two
/// messages' citations never cross-highlight.
@MainActor
@Observable
final class CitationHighlightCoordinator {

    /// The citation index the user most recently deep-linked to, or `nil` when no
    /// highlight is active. `CitationsView` keys its scroll + flash off this.
    private(set) var target: Int?

    /// Monotonic token bumped on every request so the auto-clear `Task` only
    /// clears the highlight it itself scheduled — re-tapping the same marker
    /// before the previous clear fires must restart, not cancel, the flash.
    private var requestToken = 0

    /// Deep-link to the citation at `index`: set the highlight, then auto-clear
    /// after `highlightDuration`. Re-entrant: a second request supersedes the
    /// pending clear so rapid taps don't leave a stuck highlight.
    func highlight(index: Int) {
        target = index
        requestToken += 1
        let token = requestToken
        Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.highlightDuration))
            } catch {
                // Cancellation is the only expected error here (the bubble went
                // away, or the structured task was torn down). Either way there is
                // nothing to clear — bail without touching state.
                return
            }
            guard let self, self.requestToken == token else { return }
            self.target = nil
        }
    }

    /// How long the transient flash stays on a deep-linked source card.
    static let highlightDuration: Double = 2.0
}
