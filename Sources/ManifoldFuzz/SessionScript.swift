import Foundation

/// Declarative multi-turn fuzz corpus entry. Each `Step` is interpreted by
/// ``SessionScriptRunner`` against a real ``InferenceService``, so scripts
/// exercise queue FIFO, cancellation races, and latest-wins load tokens that
/// single-turn fuzzing can't reach.
///
/// Scripts are stored as JSON under `Resources/session_scripts/*.json` and
/// loaded via ``SessionScript/loadAll()``.
public struct SessionScript: Codable, Sendable, Equatable {
    public let id: String
    public let steps: [Step]

    /// Optional per-session metadata. `systemPrompt` is applied to every
    /// `.send` / `.regenerate` unless the step overrides it (it can't today —
    /// override is reserved for a follow-up PR).
    public let systemPrompt: String?

    /// Optional session id label. The runner maps this to a `UUID` so
    /// interleaved scripts with the same label share a session.
    public let sessionLabel: String?

    public init(
        id: String,
        steps: [Step],
        systemPrompt: String? = nil,
        sessionLabel: String? = nil
    ) {
        self.id = id
        self.steps = steps
        self.systemPrompt = systemPrompt
        self.sessionLabel = sessionLabel
    }

    public enum Step: Codable, Sendable, Equatable {
        /// Append a user message and start a generation turn.
        case send(text: String)
        /// Request the active generation to stop.
        case stop
        /// Replace the message at `messageIndex` with `newText`. Does not
        /// itself trigger generation — pair with `.regenerate`.
        case edit(messageIndex: Int, newText: String)
        /// Re-run generation from the current message history. Drops the
        /// previous assistant turn (if any) before enqueuing.
        case regenerate
        /// Delete the message at `messageIndex`. Does not trigger generation.
        case delete(messageIndex: Int)

        // Custom codable using a discriminator `op` field so JSON is
        // human-authorable. Swift's synthesized codable for associated-value
        // enums produces a single-element dictionary shape that's clunky to
        // hand-write.

        private enum CodingKeys: String, CodingKey {
            case op
            case text
            case messageIndex
            case newText
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let op = try c.decode(String.self, forKey: .op)
            switch op {
            case "send":
                self = .send(text: try c.decode(String.self, forKey: .text))
            case "stop":
                self = .stop
            case "edit":
                self = .edit(
                    messageIndex: try c.decode(Int.self, forKey: .messageIndex),
                    newText: try c.decode(String.self, forKey: .newText)
                )
            case "regenerate":
                self = .regenerate
            case "delete":
                self = .delete(messageIndex: try c.decode(Int.self, forKey: .messageIndex))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .op,
                    in: c,
                    debugDescription: "Unknown SessionScript.Step op '\(op)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .send(let text):
                try c.encode("send", forKey: .op)
                try c.encode(text, forKey: .text)
            case .stop:
                try c.encode("stop", forKey: .op)
            case .edit(let idx, let newText):
                try c.encode("edit", forKey: .op)
                try c.encode(idx, forKey: .messageIndex)
                try c.encode(newText, forKey: .newText)
            case .regenerate:
                try c.encode("regenerate", forKey: .op)
            case .delete(let idx):
                try c.encode("delete", forKey: .op)
                try c.encode(idx, forKey: .messageIndex)
            }
        }
    }
}

public extension SessionScript {

    /// Loads every bundled session script. Scripts are shipped as JSON
    /// resources under `Resources/session_scripts/` at source level; Swift
    /// Package's `.process("Resources")` strategy flattens them into the
    /// module bundle's root, so the loader searches by known filename.
    ///
    /// Each file may contain either a single `SessionScript` or an array of
    /// them — the loader auto-detects so multi-session adversarial scripts
    /// (see `session-swap.json`) can share a file.
    ///
    /// The bundled set is enumerated explicitly to avoid colliding with the
    /// single-turn `seeds.json` corpus, which lives in the same bundle root.
    static let bundledScriptNames: [String] = [
        "edit-then-regenerate",
        "rapid-send-cancel",
        "session-swap",
    ]

    static func loadAll() -> [SessionScript] {
        var out: [SessionScript] = []
        let decoder = JSONDecoder()
        for name in bundledScriptNames {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
                let msg = "SessionScript.loadAll: missing bundled resource \(name).json"
                FileHandle.standardError.write(Data((msg + "\n").utf8))
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            if let one = try? decoder.decode(SessionScript.self, from: data) {
                out.append(one)
                continue
            }
            if let many = try? decoder.decode([SessionScript].self, from: data) {
                out.append(contentsOf: many)
                continue
            }
            let msg = "SessionScript.loadAll: failed to decode \(name).json as SessionScript or [SessionScript]"
            FileHandle.standardError.write(Data((msg + "\n").utf8))
        }
        return out
    }
}
