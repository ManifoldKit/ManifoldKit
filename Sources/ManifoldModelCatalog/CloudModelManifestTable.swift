import Foundation

/// Vendored prefix table that maps cloud model names to ``ModelManifest``
/// values.
///
/// Cloud backends (OpenAI, Claude) cannot introspect models at runtime —
/// the wire APIs return only token counts, not capability metadata. The
/// host-app-supplied `modelName` is the one signal we have, so the table
/// matches the configured name against a longest-prefix-wins list of
/// manifests.
///
/// Coverage is best-effort and intentionally narrow. Anything that doesn't
/// match falls through to ``ModelManifest/unknown(modelIdentifier:producerKind:)``,
/// which is conservative (no tools, no thinking, no seed) and reports **no**
/// context window at all — `nil`, not a plausible number. Each backend names
/// its own fallback for that case. A missing entry never crashes — it just
/// means the host's model name needs to be added here.
///
/// To add a new model, append a tuple to ``openAIManifests`` /
/// ``claudeManifests`` keyed by the longest prefix that uniquely identifies
/// the family. The lookup walks the array longest-prefix-first and returns
/// the first match.
public enum CloudModelManifestTable {

    // MARK: - OpenAI

    /// Longest-prefix-wins table for OpenAI Chat Completions models.
    ///
    /// Reasoning models (`o1`, `o3`, `o4`) reject `seed` — most production
    /// stacks return HTTP 400 if a seed field is present. `gpt-4o` and
    /// `gpt-4-turbo` accept it. Update this list as new families ship.
    public static let openAIManifests: [(prefix: String, manifest: ModelManifest)] = [
        // Reasoning families: large context, no seed, native thinking via
        // `reasoning` / `reasoning_content` deltas (no inline markers).
        ("o4-mini",      reasoning(name: "o4-mini",      contextWindow: 200_000)),
        ("o4",           reasoning(name: "o4",           contextWindow: 200_000)),
        ("o3-mini",      reasoning(name: "o3-mini",      contextWindow: 200_000)),
        ("o3",           reasoning(name: "o3",           contextWindow: 200_000)),
        ("o1-preview",   reasoning(name: "o1-preview",   contextWindow: 128_000)),
        ("o1-mini",      reasoning(name: "o1-mini",      contextWindow: 128_000)),
        ("o1",           reasoning(name: "o1",           contextWindow: 200_000)),
        // Chat families.
        ("gpt-4o-mini",  chat(name: "gpt-4o-mini",  contextWindow: 128_000)),
        ("gpt-4o",       chat(name: "gpt-4o",       contextWindow: 128_000)),
        ("gpt-4-turbo",  chat(name: "gpt-4-turbo",  contextWindow: 128_000)),
        ("gpt-4.1-mini", chat(name: "gpt-4.1-mini", contextWindow: 1_000_000)),
        ("gpt-4.1",      chat(name: "gpt-4.1",      contextWindow: 1_000_000)),
        ("gpt-4",        chat(name: "gpt-4",        contextWindow: 8192)),
        ("gpt-3.5-turbo", chat(name: "gpt-3.5-turbo", contextWindow: 16_385)),
    ]

    // MARK: - Claude (Anthropic)

    /// Longest-prefix-wins table for Anthropic Messages API models.
    ///
    /// All Claude families accept the same sampling parameters (temperature,
    /// top_p, top_k) and reject `seed`. Extended-thinking families surface
    /// reasoning via `thinking_delta` blocks (no inline markers).
    public static let claudeManifests: [(prefix: String, manifest: ModelManifest)] = [
        // Claude 4 family — extended thinking is standard.
        ("claude-opus-4-7",     anthropic(name: "claude-opus-4-7",     contextWindow: 1_000_000, thinking: true)),
        ("claude-opus-4-6",     anthropic(name: "claude-opus-4-6",     contextWindow: 200_000,   thinking: true)),
        ("claude-opus-4-5",     anthropic(name: "claude-opus-4-5",     contextWindow: 200_000,   thinking: true)),
        ("claude-opus-4-1",     anthropic(name: "claude-opus-4-1",     contextWindow: 200_000,   thinking: true)),
        ("claude-opus-4",       anthropic(name: "claude-opus-4",       contextWindow: 200_000,   thinking: true)),
        ("claude-sonnet-4-7",   anthropic(name: "claude-sonnet-4-7",   contextWindow: 1_000_000, thinking: true)),
        ("claude-sonnet-4-6",   anthropic(name: "claude-sonnet-4-6",   contextWindow: 200_000,   thinking: true)),
        ("claude-sonnet-4-5",   anthropic(name: "claude-sonnet-4-5",   contextWindow: 200_000,   thinking: true)),
        ("claude-sonnet-4",     anthropic(name: "claude-sonnet-4",     contextWindow: 200_000,   thinking: true)),
        ("claude-haiku-4",      anthropic(name: "claude-haiku-4",      contextWindow: 200_000,   thinking: true)),
        // Claude 3.7 — extended thinking introduced.
        ("claude-3-7-sonnet",   anthropic(name: "claude-3-7-sonnet",   contextWindow: 200_000,   thinking: true)),
        // Claude 3.5 — no extended thinking.
        ("claude-3-5-sonnet",   anthropic(name: "claude-3-5-sonnet",   contextWindow: 200_000,   thinking: false)),
        ("claude-3-5-haiku",    anthropic(name: "claude-3-5-haiku",    contextWindow: 200_000,   thinking: false)),
        // Claude 3 baseline.
        ("claude-3-opus",       anthropic(name: "claude-3-opus",       contextWindow: 200_000,   thinking: false)),
        ("claude-3-sonnet",     anthropic(name: "claude-3-sonnet",     contextWindow: 200_000,   thinking: false)),
        ("claude-3-haiku",      anthropic(name: "claude-3-haiku",      contextWindow: 200_000,   thinking: false)),
        // Generic catch for date-suffixed families. Order matters: more
        // specific entries above must precede this one.
        ("claude-sonnet",       anthropic(name: "claude-sonnet",       contextWindow: 200_000,   thinking: true)),
        ("claude-opus",         anthropic(name: "claude-opus",         contextWindow: 200_000,   thinking: true)),
        ("claude-haiku",        anthropic(name: "claude-haiku",        contextWindow: 200_000,   thinking: false)),
    ]

    // MARK: - Lookup

    /// Looks up a manifest for an OpenAI model by longest-prefix match.
    ///
    /// Returns ``ModelManifest/unknown(modelIdentifier:producerKind:)`` when
    /// no entry matches; callers should treat that as "use conservative
    /// defaults and don't pass `seed` / penalties on the wire."
    public static func openAI(modelName: String) -> ModelManifest {
        lookup(modelName: modelName, in: openAIManifests, kind: .cloud)
    }

    /// Looks up a manifest for an Anthropic Claude model by longest-prefix
    /// match.
    public static func claude(modelName: String) -> ModelManifest {
        lookup(modelName: modelName, in: claudeManifests, kind: .cloud)
    }

    /// Walks the table longest-prefix-first and returns the first hit, or
    /// ``ModelManifest/unknown(...)`` on a miss.
    private static func lookup(
        modelName: String,
        in table: [(prefix: String, manifest: ModelManifest)],
        kind: ProducerKind
    ) -> ModelManifest {
        // Sort by prefix length descending so a more specific entry like
        // `claude-3-5-sonnet` wins over `claude-3-5`.
        let sorted = table.sorted { $0.prefix.count > $1.prefix.count }
        for entry in sorted where modelName.hasPrefix(entry.prefix) {
            return entry.manifest
        }
        return .unknown(modelIdentifier: modelName, producerKind: kind)
    }

    // MARK: - Manifest Builders

    /// OpenAI Chat Completions chat model — accepts seed, presence/frequency
    /// penalties, stop sequences, top_k.
    private static func chat(name: String, contextWindow: Int) -> ModelManifest {
        ModelManifest(
            contextWindow: contextWindow,
            supportsTools: true,
            supportsThinking: false,
            thinkingMarkers: nil,
            supportsSeed: true,
            supportedSamplingParameters: [
                .temperature, .topP, .topK,
                .presencePenalty, .frequencyPenalty,
                .stopSequences,
            ],
            modelIdentifier: name,
            producerKind: .cloud
        )
    }

    /// OpenAI reasoning model (`o1`, `o3`, `o4`) — rejects seed and most
    /// sampling knobs; reasoning is a side channel (no inline markers).
    private static func reasoning(name: String, contextWindow: Int) -> ModelManifest {
        ModelManifest(
            contextWindow: contextWindow,
            supportsTools: true,
            supportsThinking: true,
            thinkingMarkers: nil,
            supportsSeed: false,
            supportedSamplingParameters: [.temperature, .topP],
            modelIdentifier: name,
            producerKind: .cloud
        )
    }

    /// Anthropic Claude model. All Claude models reject `seed`. Thinking
    /// flag depends on whether the family supports extended thinking.
    private static func anthropic(name: String, contextWindow: Int, thinking: Bool) -> ModelManifest {
        ModelManifest(
            contextWindow: contextWindow,
            supportsTools: true,
            supportsThinking: thinking,
            thinkingMarkers: nil,
            supportsSeed: false,
            supportedSamplingParameters: [
                .temperature, .topP, .topK, .stopSequences,
            ],
            modelIdentifier: name,
            producerKind: .cloud
        )
    }
}
