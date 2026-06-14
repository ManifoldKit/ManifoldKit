import XCTest
import ManifoldContract
@testable import ManifoldUI

/// Tests for ``AccessibilityAnnouncer`` using an injected recording `post`
/// closure — no live accessibility server is required. Timing-sensitive
/// behaviour uses a near-zero `minimumInterval` and deterministic awaits.
@MainActor
final class AccessibilityAnnouncerTests: XCTestCase {

    /// Records every `(text, priority)` posted through the injected seam.
    private final class Recorder {
        private(set) var posts: [(text: String, priority: AccessibilityAnnouncer.Priority)] = []
        func record(_ text: String, _ priority: AccessibilityAnnouncer.Priority) {
            posts.append((text, priority))
        }
    }

    /// Polls the recorder until it reaches `count` posts or a tight deadline
    /// elapses — deterministic without `Task.yield()` fragility.
    private func waitForPosts(
        _ recorder: Recorder,
        atLeast count: Int,
        timeout: Duration = .milliseconds(500)
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while recorder.posts.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func testOnlyAnnouncesCompletedSentences() async {
        let recorder = Recorder()
        let announcer = AccessibilityAnnouncer(
            minimumInterval: .milliseconds(1),
            post: { recorder.record($0, $1) }
        )

        // A single incomplete sentence: nothing is confirmed complete yet, so
        // nothing should post until a later boundary appears.
        announcer.ingest("Hello")
        announcer.ingest(" wor")
        announcer.ingest("ld")
        await waitForPosts(recorder, atLeast: 1, timeout: .milliseconds(50))
        XCTAssertTrue(recorder.posts.isEmpty, "Partial sentence must not announce")

        // Starting a second sentence confirms the first is complete.
        announcer.ingest(". How are you?")
        announcer.ingest(" Next") // forces the second sentence's boundary too
        await waitForPosts(recorder, atLeast: 1)
        XCTAssertFalse(recorder.posts.isEmpty)
        let firstText = recorder.posts.first?.text ?? ""
        XCTAssertTrue(firstText.contains("Hello world"), "Got: \(firstText)")
        XCTAssertEqual(recorder.posts.first?.priority, .default)
    }

    func testRateLimitCoalescesBurst() async {
        let recorder = Recorder()
        // A long-ish interval so several sentences land inside one window.
        let announcer = AccessibilityAnnouncer(
            minimumInterval: .milliseconds(80),
            post: { recorder.record($0, $1) }
        )

        // "One." is confirmed complete once "Two" starts -> first post fires
        // immediately, opening the rate-limit window.
        announcer.ingest("One. Two")
        await waitForPosts(recorder, atLeast: 1)
        XCTAssertEqual(recorder.posts.count, 1)
        XCTAssertTrue(recorder.posts[0].text.contains("One"))

        // A burst of further completed sentences inside the window must coalesce
        // into a single follow-up post, not one each.
        announcer.ingest(". Three. Four. five") // completes Two/Three/Four; "five" buffered

        await waitForPosts(recorder, atLeast: 2)
        XCTAssertEqual(recorder.posts.count, 2, "Burst must coalesce into one follow-up post")
        guard recorder.posts.count >= 2 else { return }
        // The whole burst coalesced into one announcement (the precise sentence
        // tail depends on the tokenizer's boundary decision for the buffered
        // partial; what matters is that several sentences merged into one post).
        let second = recorder.posts[1].text
        XCTAssertTrue(second.contains("Two"), "Got: \(second)")
        XCTAssertTrue(second.contains("Three"), "Got: \(second)")
    }

    func testFinishFlushesTrailingPartialAtHighPriority() async {
        let recorder = Recorder()
        let announcer = AccessibilityAnnouncer(
            minimumInterval: .milliseconds(1),
            post: { recorder.record($0, $1) }
        )

        // Trailing partial sentence with no following boundary — only `finish`
        // should surface it.
        announcer.ingest("Final partial sentence with no period")
        await waitForPosts(recorder, atLeast: 1, timeout: .milliseconds(30))
        XCTAssertTrue(recorder.posts.isEmpty, "Partial must wait for finish()")

        announcer.finish(reason: .stop)
        XCTAssertEqual(recorder.posts.count, 1)
        XCTAssertEqual(recorder.posts.last?.priority, .high)
        XCTAssertTrue(recorder.posts.last?.text.contains("Final partial") ?? false)
    }

    func testFinishCancelledSuppressesAnnouncement() async {
        let recorder = Recorder()
        let announcer = AccessibilityAnnouncer(
            minimumInterval: .milliseconds(1),
            post: { recorder.record($0, $1) }
        )

        announcer.ingest("Some buffered text without a boundary")
        announcer.finish(reason: .cancelled)
        await waitForPosts(recorder, atLeast: 1, timeout: .milliseconds(30))
        XCTAssertTrue(recorder.posts.isEmpty, "Cancelled finish must not announce")
    }

    func testFinishPostsAccumulatedPlusTail() async {
        let recorder = Recorder()
        let announcer = AccessibilityAnnouncer(
            minimumInterval: .seconds(10), // hold the rate-limit window open
            post: { recorder.record($0, $1) }
        )

        // "First." is confirmed complete only once "Second" starts; the first
        // drain post then fires immediately, opening the 10 s window.
        announcer.ingest("First. Second")
        await waitForPosts(recorder, atLeast: 1)
        XCTAssertEqual(recorder.posts.count, 1)
        XCTAssertTrue(recorder.posts[0].text.contains("First"))

        // "Second." now completes and queues, but the open window holds the
        // drain back. " tail" stays an unconfirmed partial. finish() must flush
        // both the queued "Second." and the partial "tail" at high priority.
        announcer.ingest(". tail")
        announcer.finish(reason: .stop)

        XCTAssertEqual(recorder.posts.count, 2)
        guard recorder.posts.count >= 2 else { return }
        let final = recorder.posts[1]
        XCTAssertEqual(final.priority, .high)
        XCTAssertTrue(final.text.contains("Second"))
        XCTAssertTrue(final.text.contains("tail"))
    }
}
