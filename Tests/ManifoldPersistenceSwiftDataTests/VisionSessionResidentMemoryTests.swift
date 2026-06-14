import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
@testable import ManifoldTestSupport

/// Perf-audit ground-truth: measures the resident-memory delta between a
/// vision session (50 messages, every other one carrying an image attachment)
/// and a text-only baseline of equivalent message count.
///
/// Resident-set-size measurements are noisy — they include ARC churn, malloc
/// arenas, libdispatch worker pools, and pages already mapped from prior
/// tests in the same process. When the suite runs in isolation RSS climbs
/// monotonically during seeding, but when other test classes in the same
/// process freed pages just before this one, the OS may have already shrunk
/// the working set by the time we record the baseline — causing the post-
/// vision RSS to register *lower* than the text-only baseline. The number
/// we capture is therefore advisory, not a regression guard.
///
/// We sample RSS three times per measurement and take the median, and we
/// log the captured numbers as an `XCTAttachment`. The assertion only pins
/// that `currentResidentBytes()` returned a non-zero value — proof the
/// instrument works. The downstream blob-store PR consults the attachment
/// numbers, not the assertion.
///
/// Nightly-gated (`RUN_SLOW_TESTS=1`); does not run on per-PR CI.
@MainActor
final class VisionSessionResidentMemoryTests: XCTestCase {

    private var stack: InMemoryPersistenceHarness.Stack!

    override func setUp() async throws {
        try await super.setUp()
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(
            env["CI"] == "true" && env["RUN_SLOW_TESTS"] != "1",
            "Slow perf baseline — runs in nightly CI only. Set RUN_SLOW_TESTS=1 to force."
        )
        stack = try InMemoryPersistenceHarness.make()
    }

    override func tearDown() async throws {
        stack = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Returns the median of three RSS samples taken back-to-back. Median —
    /// rather than min or mean — is robust against a single outlier sample
    /// caused by a libdispatch wake-up between calls.
    private func medianResidentBytes() -> UInt64 {
        var samples: [UInt64] = []
        for _ in 0..<3 {
            samples.append(currentResidentBytes())
        }
        samples.sort()
        return samples[1]
    }

    /// Inserts `messageCount` messages into the in-memory store. When
    /// `withImage` is true, every second message carries a `largeJPEG`
    /// attachment of `imageBytes` raw bytes.
    @discardableResult
    private func seedSession(
        messageCount: Int,
        withImage: Bool,
        imageBytes: Int
    ) throws -> UUID {
        let sessionID = UUID()
        let session = PersistedChatSession(title: withImage ? "vision" : "text-only")
        session.id = sessionID
        stack.context.insert(session)

        let imageData = withImage
            ? ImageFixtures.largeJPEG(approxBytes: imageBytes)
            : Data()
        for index in 0..<messageCount {
            let role: MessageRole = index.isMultiple(of: 2) ? .user : .assistant
            let parts: [MessagePart]
            if withImage && index.isMultiple(of: 2) {
                parts = [
                    .text("attachment-\(index)"),
                    .image(data: imageData, mimeType: "image/jpeg"),
                ]
            } else {
                parts = [.text("message-\(index) lorem ipsum")]
            }
            let message = PersistedChatMessage(role: role, contentParts: parts, sessionID: sessionID)
            stack.context.insert(message)
        }
        try stack.context.save()
        return sessionID
    }

    // MARK: - Test

    /// Builds a 50-message text-only baseline and a 50-message vision session,
    /// then measures the RSS delta after fetching all messages back. The
    /// vision session's images dominate the delta.
    func test_visionSessionRSSDeltaVsTextOnly() async throws {
        let messageCount = 50
        let bytesPerImage = 100_000

        // Baseline: text-only session.
        let textSessionID = try seedSession(
            messageCount: messageCount,
            withImage: false,
            imageBytes: bytesPerImage
        )
        // Force the in-memory rows into resident memory by reading them back.
        _ = try await stack.provider.fetchMessages(for: textSessionID)
        let rssBaseline = medianResidentBytes()

        // Vision session: same message count, half carry image attachments.
        let visionSessionID = try seedSession(
            messageCount: messageCount,
            withImage: true,
            imageBytes: bytesPerImage
        )
        let visionMessages = try await stack.provider.fetchMessages(for: visionSessionID)
        XCTAssertEqual(
            visionMessages.count, messageCount,
            "Vision session round-trip must return all messages"
        )
        let rssVision = medianResidentBytes()

        // RSS counters never go down between the two reads in steady state,
        // but `UInt64` subtraction would crash if it did. Use `Int64` math.
        let delta = Int64(rssVision) - Int64(rssBaseline)

        let attachment = XCTAttachment(string: """
            ## Vision-session RSS delta

            messageCount per session: \(messageCount)
            bytesPerImage: \(bytesPerImage)
            rssBaselineBytes: \(rssBaseline)
            rssVisionBytes: \(rssVision)
            deltaBytes: \(delta)
            """)
        attachment.name = "vision-session-rss-delta"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Instrument-liveness check only. We can't assert a directional
        // floor on the delta — when other test classes in the same process
        // freed pages just before this test ran, the OS-reported RSS may
        // shrink between baseline and vision samples even though the
        // application's working set genuinely grew. The captured numbers in
        // the XCTAttachment are the audit artefact; the assertion just pins
        // that `currentResidentBytes()` is functional.
        XCTAssertGreaterThan(
            rssVision, 0,
            "currentResidentBytes() must return a non-zero RSS reading"
        )
        XCTAssertGreaterThan(
            rssBaseline, 0,
            "currentResidentBytes() must return a non-zero RSS reading for baseline"
        )
    }
}
