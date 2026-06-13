import Foundation
import ManifoldInference

public struct RunRecord: Codable, Sendable, Equatable {
    /// Current `RunRecord` on-disk schema. Bump when the shape changes.
    /// See `ManifoldFuzz.docc/RunRecordSchema.md` for the evolution procedure.
    public static let currentSchema: Int = 1

    /// Version of the on-disk shape this record was written with. Legacy records
    /// without the field decode as `1` via `init(from:)` below.
    public var schemaVersion: Int = Self.currentSchema
    public var runId: String
    public var ts: String
    public var harness: HarnessSnapshot
    public var model: ModelSnapshot
    public var config: ConfigSnapshot
    public var prompt: PromptSnapshot
    public var events: [EventSnapshot]
    public var raw: String
    /// User-visible string produced by running `raw` through the same
    /// markdown / code-fence transform that `ManifoldUI`'s
    /// `AssistantMarkdownView` applies (see
    /// ``ManifoldInference/MarkdownRendering/renderToVisibleString(_:)``).
    ///
    /// Diverges from `raw` in realistic ways: closing fences disappear,
    /// emphasis markers collapse, link targets are hidden, partial fences
    /// fall back to plain markdown the way the streaming UI does. Detectors
    /// that read `rendered` therefore catch UI-layer rendering bugs (mid-stream
    /// cancellation breakage, partial-fence mis-termination, grapheme-cluster
    /// edge cases) that detectors reading `raw` cannot.
    ///
    /// Wired through #543 (follow-up to #499). Replay records written before
    /// that change had `rendered == raw`; `init(from:)` decodes them as-is.
    public var rendered: String
    public var thinkingRaw: String
    public var thinkingParts: [String]
    public var thinkingCompleteCount: Int
    public var templateMarkers: MarkerSnapshot?
    public var memory: MemorySnapshot
    public var timing: TimingSnapshot
    public var phase: String
    public var error: String?
    /// Coarse stop classification: `naturalStop`, `maxTokens`, `userStop`, `error`, `unknown`.
    /// Detectors gate on this to avoid false positives from token-cap truncation.
    public var stopReason: String?
    /// Tool calls emitted by the model during this run. `EventRecorder` populates
    /// this from `.toolCall` events; legacy backends with no tool support yield an
    /// empty array. Captured in full so `ToolCallValidityDetector` can re-validate
    /// arguments against the schema declared in `toolDefinitions`.
    public var toolCalls: [ToolCall]
    /// Tool results fed back into the loop. Mirrors `toolCalls` shape.
    public var toolResults: [ToolResult]
    /// Snapshot of the tool definitions made available to the model for this run.
    /// Empty when the run did not configure tools. Schema validation in
    /// `ToolCallValidityDetector.schema-violation` matches `ToolCall.toolName` against
    /// this array; calls naming an unknown tool currently skip the schema
    /// check silently — adding a dedicated `unknown-tool-name` sub-check is
    /// tracked as a follow-up to #627.
    public var toolDefinitions: [ToolDefinition]

    public init(
        schemaVersion: Int = RunRecord.currentSchema,
        runId: String,
        ts: String,
        harness: HarnessSnapshot,
        model: ModelSnapshot,
        config: ConfigSnapshot,
        prompt: PromptSnapshot,
        events: [EventSnapshot],
        raw: String,
        rendered: String,
        thinkingRaw: String,
        thinkingParts: [String],
        thinkingCompleteCount: Int,
        templateMarkers: MarkerSnapshot? = nil,
        memory: MemorySnapshot,
        timing: TimingSnapshot,
        phase: String,
        error: String? = nil,
        stopReason: String? = nil,
        toolCalls: [ToolCall] = [],
        toolResults: [ToolResult] = [],
        toolDefinitions: [ToolDefinition] = []
    ) {
        self.schemaVersion = schemaVersion
        self.runId = runId
        self.ts = ts
        self.harness = harness
        self.model = model
        self.config = config
        self.prompt = prompt
        self.events = events
        self.raw = raw
        self.rendered = rendered
        self.thinkingRaw = thinkingRaw
        self.thinkingParts = thinkingParts
        self.thinkingCompleteCount = thinkingCompleteCount
        self.templateMarkers = templateMarkers
        self.memory = memory
        self.timing = timing
        self.phase = phase
        self.error = error
        self.stopReason = stopReason
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.toolDefinitions = toolDefinitions
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case runId, ts, harness, model, config, prompt, events, raw, rendered
        case thinkingRaw, thinkingParts, thinkingCompleteCount, templateMarkers
        case memory, timing, phase, error, stopReason
        case toolCalls, toolResults, toolDefinitions
    }

    /// Decodes a record, defaulting `schemaVersion` to `1` when the field is
    /// absent so legacy on-disk records round-trip cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.runId = try c.decode(String.self, forKey: .runId)
        self.ts = try c.decode(String.self, forKey: .ts)
        self.harness = try c.decode(HarnessSnapshot.self, forKey: .harness)
        self.model = try c.decode(ModelSnapshot.self, forKey: .model)
        self.config = try c.decode(ConfigSnapshot.self, forKey: .config)
        self.prompt = try c.decode(PromptSnapshot.self, forKey: .prompt)
        self.events = try c.decode([EventSnapshot].self, forKey: .events)
        self.raw = try c.decode(String.self, forKey: .raw)
        self.rendered = try c.decode(String.self, forKey: .rendered)
        self.thinkingRaw = try c.decode(String.self, forKey: .thinkingRaw)
        self.thinkingParts = try c.decode([String].self, forKey: .thinkingParts)
        self.thinkingCompleteCount = try c.decode(Int.self, forKey: .thinkingCompleteCount)
        self.templateMarkers = try c.decodeIfPresent(MarkerSnapshot.self, forKey: .templateMarkers)
        self.memory = try c.decode(MemorySnapshot.self, forKey: .memory)
        self.timing = try c.decode(TimingSnapshot.self, forKey: .timing)
        self.phase = try c.decode(String.self, forKey: .phase)
        self.error = try c.decodeIfPresent(String.self, forKey: .error)
        self.stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
        // Default empty for legacy records written before `ToolCallValidityDetector`
        // landed; keeps round-trip stable.
        self.toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        self.toolResults = try c.decodeIfPresent([ToolResult].self, forKey: .toolResults) ?? []
        self.toolDefinitions = try c.decodeIfPresent([ToolDefinition].self, forKey: .toolDefinitions) ?? []
    }

    /// Errors surfaced by `validate(schemaVersion:)`.
    public enum SchemaError: Error, Equatable, Sendable {
        /// Raised when a record's `schemaVersion` exceeds `currentSchema` — the
        /// loader is from an older build than the writer and cannot be trusted
        /// to interpret the payload.
        case unsupportedFutureSchema(Int)
    }

    /// Validates a decoded record's `schemaVersion`. Future versions throw;
    /// older-than-current versions log a warning so callers know a migration
    /// is being applied. The `--replay` loader (#490) will call this before
    /// acting on a record.
    public static func validate(schemaVersion v: Int) throws {
        if v > currentSchema {
            throw SchemaError.unsupportedFutureSchema(v)
        }
        if v < currentSchema {
            Log.inference.warning(
                "RunRecord: decoding legacy schemaVersion \(v, privacy: .public) (current is \(currentSchema, privacy: .public)); migration shim applied."
            )
        }
    }

    public struct HarnessSnapshot: Codable, Sendable, Equatable {
        public var fuzzVersion: String
        public var packageGitRev: String
        public var packageGitDirty: Bool
        public var swiftVersion: String
        public var osBuild: String
        public var thermalState: String
    }

    public struct ModelSnapshot: Codable, Sendable, Equatable {
        public var backend: String
        public var id: String
        public var url: String
        public var fileSHA256: String?
        public var tokenizerHash: String?
        /// Per-model memory budget in bytes. `MemoryGrowthDetector` compares
        /// `MemorySnapshot.peakBytes` against this to flag runaway resident
        /// growth. Optional so capture paths that can't supply a budget leave
        /// the growth-budget branch a no-op rather than firing on missing data.
        public var memoryBudgetBytes: UInt64?

        public init(
            backend: String,
            id: String,
            url: String,
            fileSHA256: String? = nil,
            tokenizerHash: String? = nil,
            memoryBudgetBytes: UInt64? = nil
        ) {
            self.backend = backend
            self.id = id
            self.url = url
            self.fileSHA256 = fileSHA256
            self.tokenizerHash = tokenizerHash
            self.memoryBudgetBytes = memoryBudgetBytes
        }
    }

    public struct ConfigSnapshot: Codable, Sendable, Equatable {
        public var seed: UInt64
        public var temperature: Float
        public var topP: Float
        public var maxTokens: Int?
        public var systemPrompt: String?
        /// `auto` | `none` | `required` | `tool:<name>`. `nil` when this run did
        /// not configure tools. `ToolCallValidityDetector.toolchoice-violation`
        /// reads this to assert the model honoured the constraint.
        public var toolChoice: String?
        /// The model's context-window limit in tokens for this run.
        /// `ContextExhaustionSilentDetector` uses it (with the prompt-token
        /// estimate) to suppress legitimate exhaustions. Optional so capture
        /// paths that can't supply a limit leave the guard a no-op.
        public var contextLimit: Int?

        public init(
            seed: UInt64,
            temperature: Float,
            topP: Float,
            maxTokens: Int?,
            systemPrompt: String?,
            toolChoice: String? = nil,
            contextLimit: Int? = nil
        ) {
            self.seed = seed
            self.temperature = temperature
            self.topP = topP
            self.maxTokens = maxTokens
            self.systemPrompt = systemPrompt
            self.toolChoice = toolChoice
            self.contextLimit = contextLimit
        }

        private enum CodingKeys: String, CodingKey {
            case seed, temperature, topP, maxTokens, systemPrompt, toolChoice, contextLimit
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            seed = try c.decode(UInt64.self, forKey: .seed)
            temperature = try c.decode(Float.self, forKey: .temperature)
            topP = try c.decode(Float.self, forKey: .topP)
            maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
            systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
            toolChoice = try c.decodeIfPresent(String.self, forKey: .toolChoice)
            contextLimit = try c.decodeIfPresent(Int.self, forKey: .contextLimit)
        }
    }

    public struct PromptSnapshot: Codable, Sendable, Equatable {
        public var corpusId: String
        public var mutators: [String]
        public var messages: [Message]
        /// Estimated prompt-token count for this run.
        /// `ContextExhaustionSilentDetector` compares it against
        /// `ConfigSnapshot.contextLimit` to suppress legitimate exhaustions.
        /// Optional so capture paths without a tokenizer leave the guard a no-op.
        public var estimatedPromptTokens: Int?

        public init(
            corpusId: String,
            mutators: [String],
            messages: [Message],
            estimatedPromptTokens: Int? = nil
        ) {
            self.corpusId = corpusId
            self.mutators = mutators
            self.messages = messages
            self.estimatedPromptTokens = estimatedPromptTokens
        }

        public struct Message: Codable, Sendable, Equatable {
            public var role: String
            public var text: String

            public init(role: String, text: String) {
                self.role = role
                self.text = text
            }
        }
    }

    public struct EventSnapshot: Codable, Sendable, Equatable {
        public var t: Double
        public var kind: String
        public var v: String?
    }

    public struct MarkerSnapshot: Codable, Sendable, Equatable {
        public var open: String
        public var close: String
        public init(open: String, close: String) {
            self.open = open
            self.close = close
        }
    }

    public struct MemorySnapshot: Codable, Sendable, Equatable {
        public var beforeBytes: UInt64?
        public var peakBytes: UInt64?
        public var afterBytes: UInt64?
    }

    public struct TimingSnapshot: Codable, Sendable, Equatable {
        public var firstTokenMs: Double?
        public var totalMs: Double
        public var tokensPerSec: Double?
    }
}
