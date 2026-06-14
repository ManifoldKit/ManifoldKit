import Foundation
import ManifoldContract

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Posts accessibility announcements from a streaming token UI with
/// **coalesce + rate-limit + priority**, so assistive technology (VoiceOver /
/// macOS accessibility) hears completed sentence-granularity updates instead of
/// a flood of per-token re-announcements.
///
/// ## Why this exists
///
/// Streaming model output arrives as token fragments every ~33 ms. Posting an
/// accessibility announcement per token floods VoiceOver and makes the output
/// unintelligible — `ThinkingBlockView` documents *omitting* an
/// `.accessibilityValue` for exactly this reason. Every host that wants spoken
/// progress otherwise reinvents the same "coalesce a sentence, debounce, post
/// at a priority" plumbing. This is that plumbing, once, in `ManifoldUI`.
///
/// ## How to use it
///
/// Drive ``ingest(_:)`` from your token stream and call ``finish(reason:)`` when
/// the turn ends (wire it to ``ManifoldContract/GenerationEvent/generationCompleted(_:)``):
///
/// ```swift
/// let announcer = AccessibilityAnnouncer()
/// for await event in stream {
///     switch event {
///     case .token(let delta):
///         announcer.ingest(delta)
///     case .generationCompleted(let completion):
///         announcer.finish(reason: completion.reason)
///     default:
///         break
///     }
/// }
/// ```
///
/// ## What it does internally
///
/// - **Coalesce:** fragments feed ``ManifoldContract/SentenceCoalescer``; only
///   *completed* sentences are queued — partial sentences stay buffered until a
///   later boundary confirms them (or ``finish(reason:)`` flushes the tail).
/// - **Rate-limit:** a single drain `Task` posts at most one announcement per
///   ``minimumInterval``. Sentences that complete inside the window accumulate
///   and are posted together as one announcement, so a burst never floods.
/// - **Priority:** completed sentences post at ``Priority/default``; the final
///   flush from ``finish(reason:)`` posts at ``Priority/high`` so it can interrupt
///   an in-flight lower-priority announcement.
///
/// The actual post is wrapped behind an injectable `post` closure so the
/// coalesce/rate-limit/priority logic is testable without a live accessibility
/// server. Production defaults to the platform announcement API.
@MainActor
@Observable
public final class AccessibilityAnnouncer {

    /// Announcement priority, mapped to the platform's posting priority.
    ///
    /// On macOS this maps to `NSAccessibilityPriorityLevel`; on iOS the
    /// `.announcement` notification carries the same intent via its
    /// `UIAccessibility.Notification` attributed-string priority key.
    public enum Priority: Sendable {
        /// Normal streaming progress — does not interrupt a speaking announcement.
        case `default`
        /// Final / terminal announcement — may interrupt a lower-priority one.
        case high
    }

    /// The seam between this utility and the live accessibility server.
    ///
    /// Production wiring posts to the platform announcement API; tests inject a
    /// recording closure to assert on `(text, priority)` without a live server.
    public typealias PostHandler = @MainActor (_ text: String, _ priority: Priority) -> Void

    /// Minimum wall-clock interval between two posted announcements. Sentences
    /// that complete inside this window coalesce into the next post.
    public let minimumInterval: Duration

    private let post: PostHandler

    /// Completed sentences awaiting their next rate-limited post.
    private var pending: [String] = []
    /// The single in-flight drain loop. Re-armed on each ingest if idle.
    private var drainTask: Task<Void, Never>?

    private var coalescer = SentenceCoalescer()

    /// - Parameters:
    ///   - minimumInterval: Smallest gap between posted announcements. Defaults
    ///     to 0.5 s, the conventional VoiceOver debounce; tests set it near-zero.
    ///   - post: The post seam. Defaults to the platform announcement API.
    public init(
        minimumInterval: Duration = .milliseconds(500),
        post: @escaping PostHandler = AccessibilityAnnouncer.platformPost
    ) {
        self.minimumInterval = minimumInterval
        self.post = post
    }

    /// Feeds an incremental token fragment. Completed sentences are enqueued for
    /// rate-limited announcement; partial sentences stay buffered.
    public func ingest(_ tokenFragment: String) {
        let sentences = coalescer.push(tokenFragment)
        guard !sentences.isEmpty else { return }
        pending.append(contentsOf: sentences)
        scheduleDrain()
    }

    /// Flushes the trailing partial sentence and posts a final, high-priority
    /// announcement. Wire to ``ManifoldContract/GenerationEvent/generationCompleted(_:)``.
    ///
    /// A `.cancelled` reason suppresses the final announcement (nothing more
    /// should be spoken once the user cancelled); every other reason flushes the
    /// remaining buffered text immediately at ``Priority/high``.
    public func finish(reason: GenerationCompletion.Reason = .stop) {
        if let tail = coalescer.flush(), !tail.isEmpty {
            pending.append(tail)
        }

        // Cancel the pending drain and the rate-limit wait, then post the
        // accumulated text right away — a terminal announcement should not be
        // held back by the inter-post gap.
        drainTask?.cancel()
        drainTask = nil

        guard reason != .cancelled else {
            pending.removeAll()
            return
        }

        let text = joined(pending)
        pending.removeAll()
        guard !text.isEmpty else { return }
        post(text, .high)
    }

    /// Drops buffered state without posting. Use when reusing the announcer for a
    /// fresh turn after a cancellation.
    public func reset() {
        drainTask?.cancel()
        drainTask = nil
        pending.removeAll()
        coalescer = SentenceCoalescer()
    }

    // MARK: - Rate-limited drain

    /// Arms the single drain loop if it is not already running. The loop posts
    /// the currently-pending sentences, waits ``minimumInterval``, then posts any
    /// that accumulated during the wait — coalescing a burst into few posts.
    private func scheduleDrain() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.pending.isEmpty {
                let text = self.joined(self.pending)
                self.pending.removeAll()
                if !text.isEmpty {
                    self.post(text, .default)
                }
                do {
                    try await Task.sleep(for: self.minimumInterval)
                } catch {
                    // Cancellation (e.g. `finish`/`reset`) breaks the loop; the
                    // terminal post is handled by the caller.
                    break
                }
            }
            self.drainTask = nil
        }
    }

    /// Joins sentence segments into one announcement string, normalising the
    /// inter-segment whitespace the coalescer preserves so a burst reads as one
    /// flowing announcement.
    private func joined(_ segments: [String]) -> String {
        segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Platform post

    /// The default production post: routes to the platform accessibility
    /// announcement API. Gated for the n-1 OS floor (macOS 15 / iOS 18).
    public static func platformPost(_ text: String, _ priority: Priority) {
        guard !text.isEmpty else { return }
        #if canImport(UIKit)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .accessibilitySpeechQueueAnnouncement: priority == .default
            ]
        )
        UIAccessibility.post(notification: .announcement, argument: attributed)
        #elseif canImport(AppKit)
        let level: NSAccessibilityPriorityLevel = priority == .high ? .high : .medium
        if let app = NSApp, let window = app.mainWindow ?? app.windows.first {
            NSAccessibility.post(
                element: window,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: text,
                    .priority: level.rawValue,
                ]
            )
        }
        #endif
    }
}
