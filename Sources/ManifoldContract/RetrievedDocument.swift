import Foundation

/// A retrieved RAG passage threaded into a chat template's `documents` context
/// variable (#1967).
///
/// Hugging Face grounded-generation / RAG chat templates (Command-R and the
/// families that copied its convention) iterate
/// `{% for document in documents %}` and read `document.title` / `document.text`
/// (Command-R also indexes by `document.doc_id`). ManifoldKit's embedded-Jinja
/// render path threads retrieved passages through as this value so those
/// branches fire instead of the previously hard-coded empty `documents: []`,
/// which kept every `{% if documents %}` branch falsey.
///
/// Distinct from the prompt-text RAG injection path (`PromptSlot`/`RAGService`
/// folds retrieved text into the *system prompt*): a template that exposes a
/// dedicated `documents` block formats the same passages the way the model was
/// trained to ground on, rather than as free-form system text.
public struct RetrievedDocument: Sendable, Hashable, Codable {

    /// Source identifier the template can cite (Command-R's `document.doc_id`).
    /// `nil` lets the renderer fall back to the document's positional index.
    public let docID: String?

    /// Human-readable source label, typically the document file name.
    public let title: String

    /// The retrieved passage text the model grounds its answer on.
    public let text: String

    public init(docID: String? = nil, title: String, text: String) {
        self.docID = docID
        self.title = title
        self.text = text
    }
}
