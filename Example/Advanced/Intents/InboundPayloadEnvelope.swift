import Foundation
import ManifoldInference

/// JSON envelope written to App Group defaults by the intent (writer)
/// and read back by ``ManifoldDemoApp/handleOpenURL(_:)`` (reader).
///
/// Carries the prompt and the ``MessagePart`` attachments verbatim —
/// `MessagePart` is itself `Codable`, so the envelope round-trips
/// images, tool calls, and tool results without bespoke serialisation.
/// Future inbound surfaces (Share / Action Extensions on #440 / #441)
/// can populate ``attachments`` and have them ferry through to
/// ``ChatViewModel/ingest(_:)`` end-to-end.
///
/// The ``attachments`` field decodes with a default-empty fallback so
/// envelopes written before the field existed still decode without
/// migration.
struct InboundPayloadEnvelope: Codable, Sendable {
    var prompt: String
    var attachments: [MessagePart]
    var source: String

    init(prompt: String, attachments: [MessagePart] = [], source: String) {
        self.prompt = prompt
        self.attachments = attachments
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case prompt, attachments, source
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.prompt = try container.decode(String.self, forKey: .prompt)
        self.attachments = try container.decodeIfPresent([MessagePart].self, forKey: .attachments) ?? []
        self.source = try container.decode(String.self, forKey: .source)
    }
}

/// App Group identifier shared between the intent (writer) and the
/// app's `.onOpenURL` handler (reader). Centralised so renaming stays
/// in one place.
///
/// The literal values here intentionally mirror ``DemoSharedAppGroup``
/// (in `Extensions/PendingSharePayload.swift`). They're duplicated rather
/// than re-exported because this file is also compiled into the
/// `ManifoldDemoUITests` target, which doesn't link the extension-shared
/// `PendingSharePayload.swift`. If you rename either constant, update
/// the other.
enum DemoAppGroup {
    static let identifier = "group.com.manifoldkit.demo"
    static let inboundKey = "bck.inbound"
    /// Key written by the Share Extension and Action Extension.
    static let pendingShareKey = "bck.pending-share"
}
