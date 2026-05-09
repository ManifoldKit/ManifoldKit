import SwiftUI
import ManifoldRuntime
import ManifoldInference

struct AssistantMarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case markdown
        case code(language: String?)
    }

    let id: Int
    let kind: Kind
    let text: String
}

// MARK: - Attributed String Cache

/// Thread-safe LRU cache for rendered `AttributedString` values.
///
/// During token streaming the assistant message grows one batch at a time.
/// All blocks except the final (growing) one are stable — their text never
/// changes. Caching avoids repeating `AttributedString(markdown:)` (an O(N)
/// Foundation call) for every stable block on every token delivery, reducing
/// total rendering work from O(N²) to O(N).
final class MarkdownAttributedStringCache: @unchecked Sendable {
    static let shared = MarkdownAttributedStringCache()

    // NSCache handles memory pressure eviction automatically.
    private let cache = NSCache<NSString, AttributedStringBox>()

    private init() {
        cache.countLimit = 500
    }

    func attributedString(for markdown: String) -> AttributedString {
        let key = markdown as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }
        let rendered = Self.render(markdown)
        cache.setObject(AttributedStringBox(rendered), forKey: key)
        return rendered
    }

    private static func render(_ markdown: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            return parsed
        }
        return AttributedString(markdown)
    }

    // NSCache requires AnyObject values.
    private final class AttributedStringBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
}

// MARK: - Parser

enum AssistantMarkdownParser {
    /// Splits an assistant message into prose / fenced-code blocks.
    ///
    /// Delegates to ``MarkdownRendering/parseBlocks(from:)`` in
    /// `ManifoldInference` so the live UI pipeline and the headless fuzz
    /// renderer (`RunRecord.rendered`) agree on fence handling — see
    /// issue #543. The only thing this wrapper adds is the SwiftUI-side
    /// `id` numbering used by `ForEach`.
    static func parseBlocks(from source: String) -> [AssistantMarkdownBlock] {
        let parsed = MarkdownRendering.parseBlocks(from: source)
        guard !parsed.isEmpty else { return [] }
        return parsed.enumerated().map { index, block in
            switch block {
            case .markdown(let text):
                return AssistantMarkdownBlock(id: index, kind: .markdown, text: text)
            case .code(let language, let code):
                return AssistantMarkdownBlock(id: index, kind: .code(language: language), text: code)
            }
        }
    }

    static func attributedString(from markdown: String) -> AttributedString {
        MarkdownAttributedStringCache.shared.attributedString(for: markdown)
    }
}

struct AssistantMarkdownView: View {
    let content: String

    @State private var blocks: [AssistantMarkdownBlock]

    init(content: String) {
        self.content = content
        self._blocks = State(initialValue: AssistantMarkdownParser.parseBlocks(from: content))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block.kind {
                case .markdown:
                    // attributedString(from:) is cache-backed — stable blocks are O(1) lookups.
                    Text(AssistantMarkdownParser.attributedString(from: block.text))
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                case .code(let language):
                    AssistantCodeBlockView(code: block.text, language: language)
                }
            }
        }
        .onChange(of: content) {
            blocks = AssistantMarkdownParser.parseBlocks(from: content)
        }
    }
}

private struct AssistantCodeBlockView: View {
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    ClipboardWriter.copy(code)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code block")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

}

#Preview("Plain Text") {
    AssistantMarkdownView(content: "Once upon a time in a land far away...")
}

#Preview("With Code Block") {
    AssistantMarkdownView(content: "Here's an example:\n\n```swift\nlet x = 42\nprint(x)\n```\n\nThat's how it works.")
}

#Preview("With Formatting") {
    AssistantMarkdownView(content: "This is **bold** and *italic* and a [link](https://example.com).")
}
