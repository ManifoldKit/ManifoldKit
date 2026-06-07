import XCTest
@testable import ManifoldInference

/// Phase 1a infrastructure shared by every future backend contract test.
///
/// Parses the `expected.jsonl` format already in production under
/// `Tests/Fixtures/ollama/tool-calls/0.3.12/` and compares it against a
/// captured `[GenerationEvent]` stream. Two compare modes:
///
/// - `.totalOrder` — strict positional match. Used for token streams and
///   single-tool-call scenarios where ordering is meaningful.
/// - `.unorderedSet(keyedBy:)` — set match keyed by a stable identifier
///   (e.g. tool name or call id). Used for parallel tool-call scenarios
///   where OpenAI Responses interleaves deltas in arbitrary order.
///
/// Every JSON key encountered during parsing is checked against
/// `knownKeys`; anything outside that set lands in `noveltyLog` so
/// `WireNoveltyAuditTest` can fail on unannounced wire-format changes.
public struct FixtureComparator {

    // MARK: - Public API

    /// Modes supported when comparing a captured `[GenerationEvent]` stream
    /// against a parsed fixture.
    public enum CompareMode {
        case totalOrder
        case unorderedSet(keyedBy: (FixtureEvent) -> String)
    }

    /// Structurally-flat representation of one row in an `expected.jsonl`
    /// file. Keys are intentionally permissive (string→Any) so we can
    /// extend the matcher without versioning the fixture format.
    public struct FixtureEvent: Equatable, Hashable {
        public let event: String
        public let fields: [String: String]  // text→raw-JSON-substring for diffability

        public init(event: String, fields: [String: String]) {
            self.event = event
            self.fields = fields
        }

        /// Stable key by event kind + tool name when present. Default
        /// fallback for `.unorderedSet`.
        public var defaultKey: String {
            if let name = fields["tool_name"] { return "\(event)/\(name)" }
            if let callId = fields["call_id"] { return "\(event)/\(callId)" }
            return event
        }
    }

    /// File:line:key entries for unknown JSON keys encountered during
    /// `parse`. Drained by `WireNoveltyAuditTest`.
    public private(set) var noveltyLog: [String] = []

    /// JSON keys this comparator knows how to interpret. New backends
    /// that introduce a wire field MUST add it here in the same PR; the
    /// novelty audit fails on anything outside the set.
    public static let knownKeys: Set<String> = [
        "event",
        "text",
        "prompt",
        "completion",
        "tool_name",
        "name",
        "arguments_contains",
        "call_id",
        "callId",
        "thinking_text",
        "signature",
        "finish_reason",
        "iterations",
    ]

    public init() {}

    // MARK: - Parsing

    /// Parses an `expected.jsonl` fixture into a sequence of
    /// `FixtureEvent`s. Logs unknown keys (file:line:key) to `noveltyLog`.
    public mutating func parse(jsonlContents: String, sourcePath: String) -> [FixtureEvent] {
        var events: [FixtureEvent] = []
        let lines = jsonlContents.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }
            guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard let event = raw["event"] as? String else { continue }

            var fields: [String: String] = [:]
            for (k, v) in raw where k != "event" {
                if !Self.knownKeys.contains(k) {
                    noveltyLog.append("\(sourcePath):\(idx + 1):\(k)")
                }
                fields[k] = String(describing: v)
            }
            events.append(.init(event: event, fields: fields))
        }
        return events
    }

    /// Projects a captured `[GenerationEvent]` stream into the same
    /// `[FixtureEvent]` shape so the same compare routine handles both
    /// sides.
    public static func project(_ events: [GenerationEvent]) -> [FixtureEvent] {
        events.compactMap { event -> FixtureEvent? in
            switch event {
            case .token(let text):
                return .init(event: "token", fields: ["text": text])
            case .usage(let prompt, let completion):
                return .init(event: "usage", fields: [
                    "prompt": String(prompt),
                    "completion": String(completion),
                ])
            case .toolCall(let call):
                return .init(event: "toolCall", fields: [
                    "tool_name": call.toolName,
                    "arguments_contains": call.arguments,
                    "call_id": call.id,
                ])
            case .toolCallStart(let callId, let name):
                return .init(event: "toolCallStart", fields: [
                    "call_id": callId,
                    "tool_name": name,
                ])
            case .toolCallArgumentsDelta(let callId, let textDelta):
                return .init(event: "toolCallArgumentsDelta", fields: [
                    "call_id": callId,
                    "text": textDelta,
                ])
            case .thinkingToken(let text):
                return .init(event: "thinkingToken", fields: ["thinking_text": text])
            case .thinkingCompleted:
                return .init(event: "thinkingCompleted", fields: [:])
            case .thinkingSignature(let sig):
                return .init(event: "thinkingSignature", fields: ["signature": sig])
            case .toolIterationLimitExceeded(let n):
                return .init(event: "toolIterationLimitExceeded", fields: ["iterations": String(n)])
            case .toolResult, .toolProgress, .toolDispatchStarted, .toolDispatchCompleted,
                 .toolCallApproved, .kvCacheReuse, .throttleDiagnostic, .prefillProgress:
                // Queue-emitted lifecycle events and progress signals are
                // not part of the wire contract — drop from projection.
                return nil
            case .handoffRequested:
                // Runtime-synthesised handoff event — never emitted by the
                // backend wire path the fixture comparator validates.
                return nil
            }
        }
    }

    // MARK: - Comparison

    /// Compares two `FixtureEvent` arrays under `mode`. Returns a list of
    /// human-readable mismatch descriptions; empty array means match.
    public static func compare(
        actual: [FixtureEvent],
        expected: [FixtureEvent],
        mode: CompareMode
    ) -> [String] {
        switch mode {
        case .totalOrder:
            return compareTotalOrder(actual: actual, expected: expected)
        case .unorderedSet(let keyedBy):
            return compareUnordered(actual: actual, expected: expected, keyedBy: keyedBy)
        }
    }

    private static func compareTotalOrder(
        actual: [FixtureEvent], expected: [FixtureEvent]
    ) -> [String] {
        var mismatches: [String] = []
        if actual.count != expected.count {
            mismatches.append("event count mismatch: actual=\(actual.count) expected=\(expected.count)")
        }
        for (idx, exp) in expected.enumerated() {
            guard idx < actual.count else {
                mismatches.append("[\(idx)] missing event: expected \(exp.event)\(exp.fields)")
                continue
            }
            let act = actual[idx]
            if act.event != exp.event {
                mismatches.append("[\(idx)] event kind: actual=\(act.event) expected=\(exp.event)")
                continue
            }
            // Field semantics:
            //   `arguments_contains` is a substring match (not equality)
            //   to keep fixtures stable across model rewordings; everything
            //   else is exact.
            for (k, expValue) in exp.fields {
                let actValue = act.fields[k] ?? ""
                if k == "arguments_contains" {
                    if !actValue.contains(expValue) {
                        mismatches.append("[\(idx)] \(exp.event).\(k): actual=\(actValue) does not contain expected substring \(expValue)")
                    }
                } else if actValue != expValue {
                    mismatches.append("[\(idx)] \(exp.event).\(k): actual=\(actValue) expected=\(expValue)")
                }
            }
        }
        return mismatches
    }

    private static func compareUnordered(
        actual: [FixtureEvent],
        expected: [FixtureEvent],
        keyedBy: (FixtureEvent) -> String
    ) -> [String] {
        var actualByKey: [String: FixtureEvent] = [:]
        for e in actual { actualByKey[keyedBy(e)] = e }
        var expectedByKey: [String: FixtureEvent] = [:]
        for e in expected { expectedByKey[keyedBy(e)] = e }

        var mismatches: [String] = []
        let missing = expectedByKey.keys.filter { actualByKey[$0] == nil }
        let extra = actualByKey.keys.filter { expectedByKey[$0] == nil }
        for k in missing { mismatches.append("missing key in actual: \(k)") }
        for k in extra { mismatches.append("unexpected key in actual: \(k)") }
        for (k, exp) in expectedByKey {
            guard let act = actualByKey[k] else { continue }
            for (fk, expValue) in exp.fields {
                let actValue = act.fields[fk] ?? ""
                if fk == "arguments_contains" {
                    if !actValue.contains(expValue) {
                        mismatches.append("[\(k)] .\(fk): \(actValue) does not contain \(expValue)")
                    }
                } else if actValue != expValue {
                    mismatches.append("[\(k)] .\(fk): actual=\(actValue) expected=\(expValue)")
                }
            }
        }
        return mismatches
    }
}

// MARK: - XCTest helper

/// Asserts that `actual` (a captured `GenerationEvent` stream) matches the
/// fixture at `fixtureURL` under `mode`. Fails with a structured diff if
/// the streams diverge.
public func XCTAssertEventsMatch(
    actual: [GenerationEvent],
    fixtureURL: URL,
    mode: FixtureComparator.CompareMode = .totalOrder,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
        var cmp = FixtureComparator()
        let expected = cmp.parse(jsonlContents: contents, sourcePath: fixtureURL.lastPathComponent)
        let projected = FixtureComparator.project(actual)
        let mismatches = FixtureComparator.compare(actual: projected, expected: expected, mode: mode)
        if !mismatches.isEmpty {
            XCTFail("""
                Fixture mismatch (\(fixtureURL.lastPathComponent)):
                  \(mismatches.joined(separator: "\n  "))
                """, file: file, line: line)
        }
        if !cmp.noveltyLog.isEmpty {
            XCTFail("Unknown JSON keys in fixture (add to FixtureComparator.knownKeys): \(cmp.noveltyLog)",
                    file: file, line: line)
        }
    } catch {
        XCTFail("Could not read fixture \(fixtureURL.path): \(error)", file: file, line: line)
    }
}
