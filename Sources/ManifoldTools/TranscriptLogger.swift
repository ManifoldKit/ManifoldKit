import Foundation

/// JSONL logger for scenario runs.
///
/// Each event is encoded as one line of JSON with a `kind` discriminator so
/// downstream tooling (CI dashboards, regression diffs) can filter without
/// knowing the full schema. Writes are flushed on every append — crash-safe
/// enough for a test harness.
///
/// The destination is **truncated (overwritten) on open by default**: a fresh
/// `--output` path must reflect exactly one run, never concatenate a re-run onto
/// a stale transcript (which corrupts downstream scoring — #2088). Pass
/// `append: true` to preserve existing content and seek to end instead — the CLI
/// uses that for the *second and later* loggers of a single invocation so the
/// per-(scenario × model) runs interleave into one file without wiping each other.
public final class TranscriptLogger {

    public enum Event {
        case prompt(scenarioId: String, system: String, user: String, requiredTools: [String], advertisedTools: [String] = [])
        case toolCall(scenarioId: String, name: String, arguments: String)
        case toolResult(scenarioId: String, name: String, content: String, errorKind: String?)
        case tokenDelta(scenarioId: String, text: String)
        case final(scenarioId: String, text: String)
        case assertion(scenarioId: String, passed: Bool, message: String)
        /// A harness/infra error that aborted the run before (or during) a model
        /// turn — e.g. the backend rejected the model (404). Recorded so the scorer
        /// can positively distinguish an infra failure from a model that ran and
        /// declined to call a tool (#2087), rather than reading a bare prompt-only
        /// transcript as a measured zero.
        case error(scenarioId: String, message: String)
    }

    private let fileHandle: FileHandle?
    private let url: URL
    private let encoder: JSONEncoder
    private let isoFormatter: ISO8601DateFormatter

    /// Run attribution stamped onto every record so a single transcript that
    /// interleaves multiple (scenario × model) runs can be scored per-model
    /// straight from the JSONL — without parsing stdout. Per-record (rather than
    /// a one-off header row) is the safer default precisely because the CLI
    /// appends every model's events to one file.
    private let backend: String?
    private let model: String?
    private let quant: String?
    /// Which repetition of an otherwise-identical (decoy level × scenario) cell
    /// this run represents — stamped per record exactly like `backend`/`model`/
    /// `quant` so ``ConformanceScorer`` can recover it from the transcript
    /// instead of the record emitter hardcoding `0`. `nil` (the default) keeps
    /// transcripts written by callers that don't supply a repeat index
    /// shape-identical to their pre-repeat form.
    private let repeatIndex: Int?

    /// - Parameters:
    ///   - url: Destination path. Parents are created on demand.
    ///   - backend: Backend family driving the run (e.g. "ollama"). Optional so
    ///     existing callers keep compiling; when set, every record carries it.
    ///   - model: Model id driving the run (e.g. "qwen3.5-9b"). Optional.
    ///   - quant: Quantization label when derivable (e.g. "Q4_K_M"). May be nil.
    ///   - repeatIndex: Which repeat of an otherwise-identical cell this run is
    ///     (see ``ScenarioCLIHarness/Options/repeatIndex``). Optional so
    ///     existing callers keep compiling; when set, every record carries it.
    ///   - append: When `false` (the default) the destination is truncated to
    ///     empty on open so a re-run overwrites rather than concatenates (#2088).
    ///     When `true`, existing content is preserved and writes seek to the end.
    public init(
        url: URL,
        backend: String? = nil,
        model: String? = nil,
        quant: String? = nil,
        repeatIndex: Int? = nil,
        append: Bool = false
    ) throws {
        self.url = url
        self.backend = backend
        self.model = model
        self.quant = quant
        self.repeatIndex = repeatIndex
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if append {
            // Preserve any existing transcript and append to its end. Used for the
            // second+ loggers of one CLI invocation so per-(scenario × model) runs
            // interleave into one file.
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            self.fileHandle = try FileHandle(forWritingTo: url)
            try self.fileHandle?.seekToEnd()
        } else {
            // Truncate-on-open: `createFile(atPath:contents:)` replaces any existing
            // file with a fresh empty one, so a re-run to the same path starts clean
            // instead of appending a second run onto the first (#2088).
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.fileHandle = try FileHandle(forWritingTo: url)
        }
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.isoFormatter = ISO8601DateFormatter()
    }

    /// Pre-`repeatIndex` signature, kept alongside the current initializer so
    /// `swift-api-digester` sees an addition rather than a removal. Source
    /// compatibility alone isn't enough here: adding a defaulted parameter to
    /// an existing public initializer still retires the old *interface*
    /// symbol the digester compares against, even though every existing call
    /// site keeps compiling (#2450 CI: `constructor TranscriptLogger.init(url:
    /// backend:model:quant:append:) has been removed`). Swift resolves a call
    /// omitting `repeatIndex` to this narrower overload rather than
    /// defaulting it on the six-parameter designated initializer, so this
    /// isn't dead code.
    public convenience init(
        url: URL,
        backend: String? = nil,
        model: String? = nil,
        quant: String? = nil,
        append: Bool = false
    ) throws {
        try self.init(
            url: url,
            backend: backend,
            model: model,
            quant: quant,
            repeatIndex: nil,
            append: append
        )
    }

    deinit {
        // deinit can't propagate; explicit do/catch avoids a bare `try?` and
        // documents that a failed close is non-actionable (the file is about
        // to be reaped with the process anyway).
        do {
            try fileHandle?.close()
        } catch {
            // Non-fatal: we're on the deinit path and have nowhere to report.
        }
    }

    public var destination: URL { url }

    public func append(_ event: Event) {
        var dict = encode(event)
        // Stamp run attribution onto every record. Keys are only added when set,
        // so transcripts produced by callers that didn't supply attribution keep
        // their original shape (backward compatible).
        if let backend { dict["backend"] = backend }
        if let model { dict["model"] = model }
        if let quant { dict["quant"] = quant }
        if let repeatIndex { dict["repeatIndex"] = repeatIndex }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        } catch {
            // Encoding a Dictionary built from statically-typed values here
            // can only fail on programmer error; surface it to stderr and
            // skip the row rather than abort the run.
            FileHandle.standardError.write(Data("TranscriptLogger: encode failed \(error)\n".utf8))
            return
        }
        fileHandle?.write(data)
        fileHandle?.write(Data("\n".utf8))
    }

    private func encode(_ event: Event) -> [String: Any] {
        let timestamp = isoFormatter.string(from: Date())
        switch event {
        case .prompt(let id, let system, let user, let requiredTools, let advertisedTools):
            // `requiredTools` is the scenario's *expected* tool set. Recording it
            // here is what lets ConformanceScorer compute ConfusionCounts (tool
            // selection precision/recall/F1) straight from the transcript —
            // matching the metric the MLX/llama soak CLIs report, so all three
            // backends are directly comparable.
            //
            // `advertisedTools` is the full set forwarded to the model on this
            // run (which may include decoy distractors when --extra-tools N > 0).
            // Omitted from the record when empty to keep baseline transcripts
            // shape-identical to their pre-decoy form.
            var dict: [String: Any] = [
                "ts": timestamp,
                "kind": "prompt",
                "scenario": id,
                "system": system,
                "user": user,
                "requiredTools": requiredTools
            ]
            if !advertisedTools.isEmpty {
                dict["advertisedTools"] = advertisedTools
            }
            return dict
        case .toolCall(let id, let name, let arguments):
            return [
                "ts": timestamp,
                "kind": "tool_call",
                "scenario": id,
                "name": name,
                "arguments": arguments
            ]
        case .toolResult(let id, let name, let content, let errorKind):
            return [
                "ts": timestamp,
                "kind": "tool_result",
                "scenario": id,
                "name": name,
                "content": content,
                "errorKind": errorKind ?? NSNull()
            ]
        case .tokenDelta(let id, let text):
            return [
                "ts": timestamp,
                "kind": "token_delta",
                "scenario": id,
                "text": text
            ]
        case .final(let id, let text):
            return [
                "ts": timestamp,
                "kind": "final",
                "scenario": id,
                "text": text
            ]
        case .assertion(let id, let passed, let message):
            return [
                "ts": timestamp,
                "kind": "assertion",
                "scenario": id,
                "passed": passed,
                "message": message
            ]
        case .error(let id, let message):
            return [
                "ts": timestamp,
                "kind": "error",
                "scenario": id,
                "message": message
            ]
        }
    }

    /// Returns the ISO timestamp prefix used for default output filenames.
    public static func defaultFilename() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "\(stamp).jsonl"
    }
}
