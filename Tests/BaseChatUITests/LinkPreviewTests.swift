import XCTest
import SwiftUI
import ViewInspector
import BaseChatInference
import BaseChatRuntime
@testable import BaseChatUI

@MainActor
final class LinkPreviewTests: XCTestCase {

    func test_detector_returnsFirstHTTPURL() throws {
        let url = try XCTUnwrap(LinkPreviewDetector.firstURL(in: "Read https://example.com/a then https://swift.org"))

        XCTAssertEqual(url.absoluteString, "https://example.com/a")
    }

    func test_detector_ignoresNonHTTPURL() {
        XCTAssertNil(LinkPreviewDetector.firstURL(in: "Email mailto:hello@example.com"))
    }

    func test_resolver_invokesProviderWithFirstURL() async throws {
        let recorder = LinkPreviewProviderRecorder(metadata: LinkPreviewMetadata(
            url: URL(string: "https://example.com/article")!,
            title: "Example article",
            summary: "Short summary",
            siteName: "Example"
        ))

        let phase = await LinkPreviewResolver.resolve(
            text: "See https://example.com/article for details",
            provider: { url in await recorder.resolve(url) }
        )

        let invokedURLs = await recorder.invokedURLs()
        XCTAssertEqual(invokedURLs, [URL(string: "https://example.com/article")!])
        XCTAssertEqual(phase, .loaded(LinkPreviewMetadata(
            url: URL(string: "https://example.com/article")!,
            title: "Example article",
            summary: "Short summary",
            siteName: "Example"
        )))
    }

    func test_resolverWithNilProviderOptsOutWithoutFetching() async {
        let phase = await LinkPreviewResolver.resolve(
            text: "No fetch for https://example.com/private",
            provider: nil
        )

        XCTAssertEqual(phase, .idle)
    }

    func test_resolverMapsNilMetadataToUnavailable() async {
        let phase = await LinkPreviewResolver.resolve(
            text: "No preview for https://example.com/no-preview",
            provider: { url in
                XCTAssertEqual(url.absoluteString, "https://example.com/no-preview")
                return nil
            }
        )

        XCTAssertEqual(phase, .unavailable(URL(string: "https://example.com/no-preview")!))
    }

    func test_cardRendersMetadataState() throws {
        let metadata = LinkPreviewMetadata(
            url: URL(string: "https://example.com/article")!,
            title: "Example article",
            summary: "A compact preview summary",
            siteName: "Example"
        )

        let view = LinkPreviewCard(metadata: metadata)

        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "link-preview-card")
        XCTAssertNoThrow(try view.inspect().find(text: "Example"))
        XCTAssertNoThrow(try view.inspect().find(text: "Example article"))
        XCTAssertNoThrow(try view.inspect().find(text: "A compact preview summary"))
    }

    func test_messageBubbleAcceptsLinkPreviewProviderSeam() {
        let message = ChatMessageRecord(
            role: .assistant,
            content: "See https://example.com",
            sessionID: UUID()
        )

        let view = MessageBubbleView(
            message: message,
            isStreaming: false,
            linkPreviewProvider: { url in
                LinkPreviewMetadata(url: url, title: "Example")
            }
        )

        XCTAssertNotNil(AnyView(view))
    }
}

private actor LinkPreviewProviderRecorder {
    private let metadata: LinkPreviewMetadata?
    private(set) var urls: [URL] = []

    init(metadata: LinkPreviewMetadata?) {
        self.metadata = metadata
    }

    func resolve(_ url: URL) -> LinkPreviewMetadata? {
        urls.append(url)
        return metadata
    }

    func invokedURLs() -> [URL] {
        urls
    }
}
