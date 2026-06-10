/// A stable, extensible identifier for inference backends.
///
/// `BackendName` uses the `Notification.Name` / `URLResourceKey` pattern: a
/// thin `RawRepresentable` struct wrapping a `String`, with well-known values
/// exposed as `public static let` constants. Any backend — including
/// third-party backends added after ManifoldKit 1.0 ships — can mint a new
/// name by extending this type or simply using `BackendName(rawValue: "myBackend")`.
///
/// ## Extensibility rationale
///
/// The previous `enum BackendName` was a closed set. Switching on a closed set
/// requires callers to keep exhaustive `switch` statements in sync with every
/// new backend, coupling downstream code to ManifoldKit internals. With a
/// struct, unknown names decode and round-trip safely, and switch sites that
/// only care about a subset of backends can match the constants they know and
/// use `default:` for the rest.
///
/// ## Wire and persistence compatibility
///
/// JSON encoding/decoding uses a **single-value string container** (identical
/// to the old `enum: String` synthesis), so all persisted and wire payloads
/// are byte-identical to those produced by pre-1.0 builds.
///
/// ## Usage
///
/// ```swift
/// if vm.activeBackendName == BackendName.foundation.rawValue {
///     // Foundation-specific behaviour
/// }
/// ```
///
/// `activeBackendName` is still typed as `String?` because the lifecycle
/// coordinator also surfaces cloud providers (`lmStudio`, `custom`,
/// `openAIResponses`) and free-form labels from test backends. For the six
/// well-known backends below, `BackendName.<name>.rawValue` is the canonical
/// comparison shape.
///
/// ## Migration from 0.19.x (enum)
///
/// `switch` statements over `BackendName` must add a `default:` arm now that
/// the type is open. `CaseIterable` is replaced by `BackendName.wellKnown`
/// (also accessible as `BackendName.allCases` for source compatibility with
/// existing call sites).
///
/// ## Why `ExpressibleByStringLiteral` is NOT conformed to
///
/// Unlike `Notification.Name` (AppKit-era), `BackendName` is a **persisted
/// dispatch discriminator**: a typo'd string literal silently mints a new,
/// unrecognised name that routes to no backend and is impossible to distinguish
/// from a legitimate unknown name at runtime. `Notification.Name` accepts the
/// typo risk because misrouted notifications fail silently and visibly; a
/// silently minted `BackendName` would cause hard-to-diagnose inference failures.
/// Use `BackendName(rawValue:)` or one of the `public static let` constants
/// instead — the compiler will catch the extra keystroke.
///
/// ## Migration from 0.18.x
///
/// In 0.18 and earlier, `BackendName` was a no-instances container of `static
/// let` strings whose values were the *display* names emitted by
/// `InferenceService.activeBackendName` (`"Apple"`, `"Ollama"`, …). 0.19
/// converted it to an `enum: String` with canonical lowercase identifiers.
/// Use ``parse(_:)`` at trust boundaries that may still hold 0.18.x strings.
public struct BackendName: RawRepresentable, Sendable, Codable, Hashable,
                           CustomStringConvertible {
    /// The canonical lowercase identifier for this backend.
    ///
    /// This value is stable across ManifoldKit releases; you may persist or
    /// transmit it freely.
    public let rawValue: String

    /// Creates a `BackendName` from any string.
    ///
    /// This initialiser is non-failable: every string is a valid backend
    /// identifier. Unrecognised names decode and round-trip safely, enabling
    /// forward-compat when a new backend is introduced.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    // MARK: CustomStringConvertible

    public var description: String { rawValue }

    // MARK: Codable — single-value string container (wire-identical to the old enum)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Well-known backends

extension BackendName {

    // Ordering matches the original enum declaration; preserved for allCases / wellKnown.

    /// The Apple Foundation Models backend (canonical raw value: `"foundation"`).
    /// Legacy 0.18 raw value: `"Apple"`.
    public static let foundation = BackendName(rawValue: "foundation")

    /// The Ollama backend (canonical raw value: `"ollama"`).
    /// Legacy 0.18 raw value: `"Ollama"`.
    public static let ollama = BackendName(rawValue: "ollama")

    /// The Claude (Anthropic) backend (canonical raw value: `"claude"`).
    /// Legacy 0.18 raw value: `"Claude"`.
    public static let claude = BackendName(rawValue: "claude")

    /// The OpenAI Chat-Completions / OpenAI-compatible backend (canonical raw value: `"openAI"`).
    /// Legacy 0.18 raw value: `"OpenAI"`.
    public static let openAI = BackendName(rawValue: "openAI")

    /// The MLX backend (canonical raw value: `"mlx"`).
    /// Legacy 0.18 raw value: `"MLX"`.
    public static let mlx = BackendName(rawValue: "mlx")

    /// The llama.cpp (GGUF) backend (canonical raw value: `"llama"`).
    /// Legacy 0.18 raw value: `"llama.cpp"`.
    public static let llama = BackendName(rawValue: "llama")

    /// The complete set of well-known backends shipped with ManifoldKit.
    ///
    /// This list is stable across patch releases. A new backend family would
    /// increment the minor version and add an entry here. Third-party backends
    /// are not listed but are fully supported via `BackendName(rawValue:)`.
    ///
    /// Replaces the `CaseIterable.allCases` synthesised property from the
    /// former `enum BackendName`. Existing code that wrote `BackendName.allCases`
    /// continues to compile via the `allCases` alias below.
    public static let wellKnown: [BackendName] = [
        .foundation, .ollama, .claude, .openAI, .mlx, .llama,
    ]

    /// Source-compatibility alias for `wellKnown`.
    ///
    /// Code that iterated `BackendName.allCases` when the type was a `CaseIterable`
    /// enum continues to compile and produce the same ordered list. New code
    /// should prefer `BackendName.wellKnown` to make the open-world nature of
    /// the identifier explicit.
    public static let allCases: [BackendName] = wellKnown
}

// MARK: - 0.18.x migration helper

extension BackendName {
    /// Accepts the 0.19+ canonical raw values *and* the 0.18.x legacy
    /// display strings (`"Apple"`, `"Ollama"`, `"llama.cpp"`, …).
    ///
    /// Use this at every trust boundary that reads a backend-name string
    /// from disk, wire formats, or persisted user defaults that may
    /// pre-date the rename. Comparing two freshly produced 0.19 strings
    /// can use `BackendName(rawValue:)` directly; ``parse(_:)`` is the
    /// migration affordance that absorbs the legacy shape so we don't
    /// strand any already-installed apps on the old form.
    ///
    /// Unlike `BackendName(rawValue:)`, this function returns `nil` for
    /// strings that don't match either the canonical or legacy forms. Use
    /// it when you want to distinguish "a known backend" from "an arbitrary
    /// string".
    public static func parse(_ string: String) -> BackendName? {
        // Fast path: check well-known raw values first.
        let candidate = BackendName(rawValue: string)
        if wellKnown.contains(candidate) { return candidate }
        // Legacy 0.18.x display-name fallbacks.
        switch string {
        case "Apple":     return .foundation
        case "Ollama":    return .ollama
        case "Claude":    return .claude
        case "OpenAI":    return .openAI
        case "MLX":       return .mlx
        case "llama.cpp": return .llama
        default:          return nil
        }
    }
}
