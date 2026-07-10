import Foundation

/// A stable, extensible identifier for the inference backend a model requires,
/// determined by its file format.
///
/// `ModelType` uses the same `Notification.Name` / `URLResourceKey` pattern as
/// ``BackendName`` (`ManifoldContract`, P2.5b): a thin `RawRepresentable` struct
/// wrapping a `String`, with well-known values exposed as `public static let`
/// constants. A new local model family — the third-party escape valve
/// `docs/COMPANION-BACKENDS.md` anticipates — can mint a new type by extending
/// this type or simply using `ModelType(rawValue: "myFamily")`, without a core
/// ManifoldKit PR.
///
/// ## Extensibility rationale
///
/// The previous `enum ModelType` was a closed 3-case set keying
/// `BackendFactory`. Switching on a closed set requires every consumer —
/// including this repo's own `ModelLoadPlan`, `ModelCapabilityTier`, and
/// download-validation switches — to keep exhaustive `switch` statements in
/// sync with every new local family, and blocks third parties from
/// registering a backend at all. With a struct, unknown model types decode
/// and round-trip safely, and switch sites that only care about a subset of
/// types can match the constants they know and use `default:` for the rest.
///
/// ## Wire and persistence compatibility
///
/// JSON encoding/decoding uses a **single-value string container** (identical
/// to the old `enum: String` synthesis would have produced), so raw values are
/// byte-identical to `"gguf"` / `"mlx"` / `"foundation"` — any code that
/// persists a `ModelType` (e.g. `ManifoldModelCatalog`'s on-disk catalog file)
/// round-trips unchanged.
///
/// ## Pattern matching
///
/// `case .gguf:` / `case .mlx:` / `case .foundation:` continue to work in a
/// `switch` over a `ModelType` value — Swift's default `~=` for any
/// `Equatable` type makes `case <static let>:` patterns work exactly like
/// enum-case patterns. The only change existing exhaustive switches need is a
/// trailing `default:` arm, because the compiler can no longer prove the
/// three well-known constants are the only possible values.
///
/// ## Usage
///
/// ```swift
/// if model.modelType == .foundation {
///     // Foundation-specific handling
/// }
/// ```
///
/// ## Migration from 0.67.x (enum)
///
/// `switch` statements over `ModelType` must add a `default:` arm now that
/// the type is open. There is no `CaseIterable` replacement — callers that
/// need "every built-in local model type" should use
/// `LocalModelDescriptor.builtIns.map(\.modelType)` (`BackendDescriptor.swift`),
/// which is the registry ManifoldKit itself treats as canonical.
public struct ModelType: RawRepresentable, Sendable, Codable, Hashable,
                         CustomStringConvertible {
    /// The canonical lowercase identifier for this model type.
    ///
    /// This value is stable across ManifoldKit releases; you may persist or
    /// transmit it freely.
    public let rawValue: String

    /// Creates a `ModelType` from any string.
    ///
    /// This initialiser is non-failable: every string is a valid model-type
    /// identifier. Unrecognised types decode and round-trip safely, enabling
    /// forward-compat when a new local model family is introduced.
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

// MARK: - Well-known model types

extension ModelType {

    // Ordering matches the original enum declaration.

    /// A single `.gguf` file — uses the llama.cpp backend (canonical raw value: `"gguf"`).
    public static let gguf = ModelType(rawValue: "gguf")

    /// A directory containing `config.json` + `.safetensors` weights — uses MLX
    /// (canonical raw value: `"mlx"`).
    public static let mlx = ModelType(rawValue: "mlx")

    /// Apple on-device model, no file needed (canonical raw value: `"foundation"`).
    public static let foundation = ModelType(rawValue: "foundation")

    /// The complete set of local model types shipped with ManifoldKit.
    ///
    /// This list is stable across patch releases. A new local model family
    /// would increment the minor version and add an entry here. Third-party
    /// model types are not listed but are fully supported via
    /// `ModelType(rawValue:)`.
    public static let wellKnown: [ModelType] = [.gguf, .mlx, .foundation]
}
