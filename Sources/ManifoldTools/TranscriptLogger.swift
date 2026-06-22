import Foundation

/// Append-only JSONL logger for scenario runs.
///
/// Each event is encoded as one line of JSON with a `kind` discriminator so
/// downstream tooling (CI dashboards, regression diffs) can filter without
/// knowing the full schema. The file is opened on first write and flushed on
/// every append — crash-safe enough for a test harness.
public final class TranscriptLogger {

    public enum Event {
        case prompt(scenarioId: String, system: String, user: String, requiredTools: [String], advertisedTools: [String] = [])
        case toolCall(scenarioId: String, name: String, arguments: String)
        case toolResult(scenarioId: String, name: String, content: String, errorKind: String?)
        case tokenDelta(scenarioId: String, text: String)
        case final(scenarioId: String, text: String)
        case assertion(scenarioId: String, passed: Bool, message: String)
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

    /// - Parameters:
    ///   - url: Destination path. Parents are created on demand.
    ///   - backend: Backend family driving the run (e.g. "ollama"). Optional so
    ///     existing callers keep compiling; when set, every record carries it.
    ///   - model: Model id driving the run (e.g. "qwen3.5-9b"). Optional.
    ///   - quant: Quantization label when derivable (e.g. "Q4_K_M"). May be nil.
    public init(
        url: URL,
        backend: String? = nil,
        model: String? = nil,
        quant: String? = nil
    ) throws {
        self.url = url
        self.backend = backend
        self.model = model
        self.quant = quant
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.fileHandle = try FileHandle(forWritingTo: url)
        try self.fileHandle?.seekToEnd()
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.isoFormatter = ISO8601DateFormatter()
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
