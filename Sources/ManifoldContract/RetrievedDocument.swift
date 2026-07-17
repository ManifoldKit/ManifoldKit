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

    /// The ingesting caller's document identity — ``DocumentChunk/documentID``
    /// for chunked hits, ``DocumentRecord/id`` for the whole-document path
    /// (#2207).
    ///
    /// Distinct from ``docID`` above: `docID` is a template-facing `String?`
    /// shaped for Command-R's `document.doc_id` convention and is never
    /// populated by `RAGService` today. `documentID` is the actual
    /// retrieval-source identity, letting a consumer post-filter
    /// `RAGService.RetrievalResult/documents` by document — e.g. excluding a
    /// document already present verbatim elsewhere in the live context —
    /// without detouring through `Citation` and re-joining on text (whose
    /// fields aren't guaranteed to match `text` exactly). `nil` only for
    /// values constructed without a backing document (e.g. ad hoc test
    /// fixtures); every hit `RAGService` produces populates it.
    public let documentID: UUID?

    /// Human-readable source label, typically the document file name.
    public let title: String

    /// The retrieved passage text the model grounds its answer on.
    public let text: String

    public init(docID: String? = nil, documentID: UUID? = nil, title: String, text: String) {
        self.docID = docID
        self.documentID = documentID
        self.title = title
        self.text = text
    }
}
