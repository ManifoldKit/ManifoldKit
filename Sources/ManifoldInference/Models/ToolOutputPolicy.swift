import Foundation

// MARK: - ToolOutputPolicy

/// Bounds the size of a ``ToolResult/content`` payload before it flows back
/// into the next generation turn.
///
/// Tool outputs ride in the conversation history as plain message text. A
/// 40 KB JSON dump from a single tool call easily exceeds the next turn's
/// budget on local models with 8K-token windows, causing silent truncation
/// at the prompt-assembly layer or, on the simulator, an out-of-memory
/// crash. ``ToolOutputPolicy`` makes the size limit explicit and gives the
/// host three options for handling oversize results.
///
/// The default ``maxBytes`` of `32_768` corresponds to roughly 8K tokens —
/// enough to round-trip a typical structured tool response without ever
/// approaching the context budget on a 32K-context model.
///
/// ## Tuning ``maxBytes``
///
/// - **Keep the default (32 KB)** for tools that return short, structured
///   data: weather lookups, calculator output, search-result summaries,
///   small DB queries. The default leaves comfortable headroom for the
///   user prompt, system prompt, and assistant reply on local 8K–32K
///   context models.
/// - **Raise it (e.g. 256 KB)** for tools that return long file reads,
///   page contents, or transcripts. Pair the bump with a backend that
///   has a 128K+ context window — Claude, GPT-4-turbo, Gemini Pro, etc.
///   Raising it on a local 8K-context model will silently push earlier
///   turns out of the prompt window.
/// - **Lower it (e.g. 4 KB)** when chaining many tools per turn — each
///   result eats budget, so capping at 4 KB per call keeps the loop
///   producing readable transcripts.
///
/// Pair the policy with ``OversizeAction``:
///
/// - ``OversizeAction/rejectWithError`` (default): the result is replaced
///   with an ``ToolResult/ErrorKind/invalidArguments`` error so the model
///   can self-correct (ask for a smaller slice, narrow the query, etc.).
///   This is the safe default — no data silently disappears.
/// - ``OversizeAction/truncate(suffix:)``: the result is trimmed at a
///   UTF-8 boundary and the suffix (default `"... [truncated]"`) is
///   appended. Use when partial output is genuinely useful, e.g. log
///   tails.
/// - ``OversizeAction/allow``: no enforcement for *successful* results.
///   Already-errored results whose content overflows are still trimmed
///   (the registry never re-classifies an existing error). Debug only —
///   disables the safety net for happy-path responses.
/// - ``OversizeAction/spillToFile(threshold:message:)``: write the
///   oversize content to a file in the caches directory and replace
///   the in-conversation payload with a short pointer message. The
///   host registers a file-reading tool that can fetch the spill back
///   on demand. See the case docs for the open-question decisions
///   (reaper, gating, sandbox volatility).
///
/// ## Example
///
/// ```swift
/// let registry = ToolRegistry()
/// registry.outputPolicy = ToolOutputPolicy(
///     maxBytes: 65_536,
///     onOversize: .truncate(suffix: "\n... [truncated for context budget]")
/// )
/// registry.register(fileReadTool)
/// ```
public struct ToolOutputPolicy: Sendable, Equatable {

    /// Maximum permitted size, in UTF-8 bytes, of a successful tool
    /// result's ``ToolResult/content``.
    ///
    /// Defaults to `32_768` (~8K tokens). The byte count is measured via
    /// `String.utf8.count` after the executor returns. Negative values
    /// are clamped to `0` at the property setter so a misconfigured host
    /// can't accidentally invert the policy and reject every result.
    public var maxBytes: Int {
        didSet { if maxBytes < 0 { maxBytes = 0 } }
    }

    /// What to do when a result exceeds ``maxBytes``.
    public var onOversize: OversizeAction

    /// Creates a policy.
    ///
    /// - Parameters:
    ///   - maxBytes: Permitted UTF-8 byte ceiling. Defaults to `32_768`.
    ///     Negative values are clamped to `0` (every successful result
    ///     becomes oversize and is handled per ``onOversize``).
    ///   - onOversize: Action when the ceiling is exceeded. Defaults to
    ///     ``OversizeAction/rejectWithError`` so oversize results surface
    ///     as a recognisable error rather than silently disappearing.
    public init(
        maxBytes: Int = 32_768,
        onOversize: OversizeAction = .rejectWithError
    ) {
        self.maxBytes = max(0, maxBytes)
        self.onOversize = onOversize
    }
}

// MARK: - OversizeAction

/// How ``ToolRegistry`` should react when a tool result's UTF-8 byte
/// length exceeds ``ToolOutputPolicy/maxBytes``.
public enum OversizeAction: Sendable {

    /// Replace the result with a
    /// ``ToolResult/ErrorKind/invalidArguments`` failure whose content
    /// describes the overflow. The model sees the error and can retry
    /// with a narrower argument (smaller slice, tighter filter).
    case rejectWithError

    /// Trim ``ToolResult/content`` to a valid UTF-8 boundary and append
    /// `suffix`. The total byte count after trim + suffix is guaranteed
    /// not to exceed ``ToolOutputPolicy/maxBytes`` — the trimmer reserves
    /// room for the suffix bytes before slicing the original payload.
    ///
    /// Trade-off: when the suffix is longer than ``ToolOutputPolicy/maxBytes``
    /// itself (a degenerate configuration), the trimmer falls back to
    /// emitting just the suffix truncated to fit. Don't configure that.
    case truncate(suffix: String)

    /// No oversize enforcement for successful results — pass them
    /// through unchanged. Already-errored results whose content
    /// overflows ``ToolOutputPolicy/maxBytes`` are still trimmed by the
    /// registry; this case never re-classifies an existing error.
    /// Intended for debug builds and tests; production hosts should
    /// keep the default ``rejectWithError`` policy.
    case allow

    /// Spill oversize content to a file in the caches directory and
    /// replace the in-conversation result with a short pointer message
    /// produced by `message`.
    ///
    /// `threshold` is the byte ceiling above which the spill triggers.
    /// In practice it should equal (or be slightly below)
    /// ``ToolOutputPolicy/maxBytes`` — the registry uses `maxBytes` for
    /// its overflow check and only consults `threshold` to decide
    /// whether the result is large enough to warrant the file-system
    /// round-trip rather than truncating in place. Results whose UTF-8
    /// size is `>= threshold` are spilled; smaller (but still oversize)
    /// results fall through to truncation with a generic suffix so we
    /// never silently lose data.
    ///
    /// `message` receives the original UTF-8 byte size and the URL of
    /// the spilled file and returns the short pointer string the model
    /// will see (e.g. `"Result spilled to /var/.../tool-spill-… — 1.4 MB.
    /// Use the read_file tool to inspect."`).
    ///
    /// Files are written to
    /// `<caches>/ManifoldKit/tool-spills/tool-spill-<ISO8601>-<UUID>.txt`.
    /// On iOS, the file is created with
    /// `NSFileProtectionCompleteUntilFirstUserAuthentication` so it is
    /// readable while the device is unlocked at least once after boot.
    ///
    /// ## Open-question decisions
    ///
    /// - **Reaper**: spilled files accumulate. Pair this case with
    ///   ``ToolSpillReaper/cleanOldSpills(maxAge:directory:)`` (the
    ///   default ``InferenceService`` initializers schedule a 7-day
    ///   sweep at startup as a fire-and-forget detached `Task`).
    /// - **File-reading-tool gating**: the host is responsible for
    ///   registering a tool that can read the spill URL back. The
    ///   registry does not gate on this — emitting a pointer to a file
    ///   the model can't access is a host configuration mistake, not a
    ///   library invariant.
    /// - **iOS sandbox volatility**: caches-directory contents may be
    ///   evicted by the OS under disk pressure. Worst case the model
    ///   re-invokes the tool when it can't read the file back. That is
    ///   acceptable: spills are a budget-relief mechanism, not durable
    ///   storage.
    ///
    /// On write failure the registry falls back to ``truncate(suffix:)``
    /// semantics with a generic suffix and logs a warning — a spill
    /// cannot be allowed to crash the chat loop.
    case spillToFile(threshold: Int, message: @Sendable (Int, URL) -> String)
}

// Hand-rolled because the `spillToFile` closure can't be auto-synthesised
// into the Equatable conformance. Two `spillToFile` actions compare equal
// when their thresholds match — closure identity is intentionally ignored,
// matching the convention closure-bearing values use elsewhere in the
// framework.
extension OversizeAction: Equatable {
    public static func == (lhs: OversizeAction, rhs: OversizeAction) -> Bool {
        switch (lhs, rhs) {
        case (.rejectWithError, .rejectWithError):
            return true
        case (.allow, .allow):
            return true
        case (.truncate(let a), .truncate(let b)):
            return a == b
        case (.spillToFile(let a, _), .spillToFile(let b, _)):
            return a == b
        default:
            return false
        }
    }
}
