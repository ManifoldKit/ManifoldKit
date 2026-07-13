import Foundation
import SwiftUI

/// Host-supplied metadata for rendering a compact preview of a URL in a chat message.
///
/// `ManifoldUI` never fetches preview metadata by default. Hosts that want link
/// previews must provide a ``LinkPreviewProvider`` so they can make their own
/// privacy and networking choices.
public struct LinkPreviewMetadata: Equatable, Sendable {
    public let url: URL
    public let title: String
    public let summary: String?
    public let siteName: String?
    public let imageURL: URL?

    public init(
        url: URL,
        title: String,
        summary: String? = nil,
        siteName: String? = nil,
        imageURL: URL? = nil
    ) {
        self.url = url
        self.title = title
        self.summary = summary
        self.siteName = siteName
        self.imageURL = imageURL
    }
}

/// Async opt-in seam for resolving link-preview metadata.
public typealias LinkPreviewProvider = @Sendable (URL) async throws -> LinkPreviewMetadata?

/// Detects previewable URLs in message text.
package enum LinkPreviewDetector {
    package static func firstURL(in text: String) -> URL? {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let match = detector.firstMatch(in: text, options: [], range: range)
        guard let url = match?.url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            return nil
        }
        return url
    }
}

package enum LinkPreviewRenderPhase: Equatable, Sendable {
    case idle
    case loading(URL)
    case loaded(LinkPreviewMetadata)
    case unavailable(URL)
}

enum LinkPreviewResolver {
    static func resolve(text: String, provider: LinkPreviewProvider?) async -> LinkPreviewRenderPhase {
        guard let provider else { return .idle }
        guard let url = LinkPreviewDetector.firstURL(in: text) else { return .idle }

        do {
            guard let metadata = try await provider(url) else {
                return .unavailable(url)
            }
            return .loaded(metadata)
        } catch {
            return .unavailable(url)
        }
    }
}

struct LinkPreviewAttachmentView: View {
    let text: String
    let provider: LinkPreviewProvider?

    @State private var phase: LinkPreviewRenderPhase = .idle

    var body: some View {
        Group {
            if case .loaded(let metadata) = phase {
                LinkPreviewCard(metadata: metadata)
            }
        }
        .task(id: taskID) {
            guard provider != nil, let url = LinkPreviewDetector.firstURL(in: text) else {
                phase = .idle
                return
            }
            phase = .loading(url)
            let resolved = await LinkPreviewResolver.resolve(text: text, provider: provider)
            guard !Task.isCancelled else { return }
            phase = resolved
        }
    }

    private var taskID: String {
        guard provider != nil, let url = LinkPreviewDetector.firstURL(in: text) else {
            return "disabled"
        }
        return url.absoluteString
    }
}

struct LinkPreviewCard: View {
    let metadata: LinkPreviewMetadata

    var body: some View {
        Link(destination: metadata.url) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "link")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    if let siteName = metadata.siteName, !siteName.isEmpty {
                        Text(siteName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("link-preview-site")
                    }

                    Text(metadata.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .accessibilityIdentifier("link-preview-title")

                    if let summary = metadata.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .accessibilityIdentifier("link-preview-summary")
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("link-preview-card")
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if let siteName = metadata.siteName, !siteName.isEmpty {
            return "\(siteName): \(metadata.title)"
        }
        return metadata.title
    }
}
