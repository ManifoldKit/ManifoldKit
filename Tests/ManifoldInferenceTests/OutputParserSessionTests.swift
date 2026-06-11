import XCTest
@testable import ManifoldInference
@testable import ManifoldContract  // #1719: streaming/tokenizer seams moved to Contract

/// Tests for ``OutputParserSession`` and the two ``StreamTransform`` stages it
/// composes (`ThinkingTransform`, `ToolCallTransform`). Covers combined
/// ordering, N-candidate tool dialects, adversarial chunk splitting at every
/// byte/character boundary, and the finalize flush + discard rules.
final class OutputParserSessionTests: XCTestCase {

    // MARK: - Event collectors

    private func visible(_ events: [GenerationEvent]) -> String {
        events.compactMap { if case .token(let t) = $0 { return t } else { return nil } }.joined()
    }

    private func thinking(_ events: [GenerationEvent]) -> String {
        events.compactMap { if case .thinkingToken(let t) = $0 { return t } else { return nil } }.joined()
    }

    private func completions(_ events: [GenerationEvent]) -> Int {
        events.filter { if case .thinkingCompleted = $0 { return true } else { return false } }.count
    }

    private func toolCalls(_ events: [GenerationEvent]) -> [ToolCall] {
        events.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }
    }

    // MARK: - Test marker fixtures

    /// A simple JSON `<tool_call>` dialect: `{"name":...}` → ToolCall.
    private func jsonMarker() -> ToolCallMarker {
        ToolCallMarker(open: "<tool_call>", close: "</tool_call>") { body in
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let name = obj["name"] as? String, !name.isEmpty
            else { return nil }
            return ToolCall(id: "json-\(name)", toolName: name, arguments: "{}")
        }
    }

    /// A second competing dialect with a *distinct* open tag for the
    /// two-candidate earliest-open tests.
    private func bracketMarker() -> ToolCallMarker {
        ToolCallMarker(open: "[[call]]", close: "[[/call]]") { body in
            let name = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return ToolCall(id: "bracket-\(name)", toolName: name, arguments: "{}")
        }
    }

    private func makeSession(thinkingThenTool: Bool, tool: [ToolCallMarker]) -> OutputParserSession {
        if thinkingThenTool {
            return OutputParserSession([
                .thinking(ThinkingTransform(markers: .qwen3)),
                .tool(ToolCallTransform(markers: tool)),
            ])
        } else {
            return OutputParserSession([
                .tool(ToolCallTransform(markers: tool)),
                .thinking(ThinkingTransform(markers: .qwen3)),
            ])
        }
    }

    /// Feed `input` as a single chunk, then finalize, returning all events.
    private func runWhole(_ session: inout OutputParserSession, _ input: String) -> [GenerationEvent] {
        session.ingest(input) + session.finalize()
    }

    // MARK: - Combined thinking + tool ordering (single-candidate)

    func test_thinkingThenTool_separatesReasoningVisibleAndToolCall() {
        var session = makeSession(thinkingThenTool: true, tool: [jsonMarker()])
        let input = "<think>reason</think>before<tool_call>{\"name\":\"get_weather\"}</tool_call>after"
        let events = runWhole(&session, input)

        XCTAssertEqual(thinking(events), "reason")
        XCTAssertEqual(completions(events), 1)
        XCTAssertEqual(visible(events), "beforeafter")
        XCTAssertEqual(toolCalls(events).map(\.toolName), ["get_weather"])

        // Sabotage: if the tool stage re-scanned thinking text, "reason" would
        // be searched for tool tags and the assertions above would shift.
    }

    func test_toolThenThinking_mlxOrder_zeroBehaviorChange() {
        var session = makeSession(thinkingThenTool: false, tool: [jsonMarker()])
        let input = "visible<tool_call>{\"name\":\"search\"}</tool_call><think>r</think>tail"
        let events = runWhole(&session, input)

        XCTAssertEqual(toolCalls(events).map(\.toolName), ["search"])
        XCTAssertEqual(thinking(events), "r")
        XCTAssertEqual(visible(events), "visibletail")
    }

    // MARK: - Two-candidate earliest-open-wins

    func test_twoCandidate_earliestOpenWins_bracketBeforeJSON() {
        // Bracket marker listed first; both opens present, bracket appears earlier.
        var session = makeSession(thinkingThenTool: true, tool: [bracketMarker(), jsonMarker()])
        let input = "x[[call]]toolA[[/call]]y<tool_call>{\"name\":\"toolB\"}</tool_call>z"
        let events = runWhole(&session, input)

        XCTAssertEqual(toolCalls(events).map(\.toolName), ["toolA", "toolB"])
        XCTAssertEqual(visible(events), "xyz")
    }

    func test_twoCandidate_tieBreaksByArrayOrder() {
        // Both markers share the SAME open tag; array order must decide which
        // parseBody runs. First wins.
        let first = ToolCallMarker(open: "<call>", close: "</call>") { _ in
            ToolCall(id: "first", toolName: "FIRST", arguments: "{}")
        }
        let second = ToolCallMarker(open: "<call>", close: "</call>") { _ in
            ToolCall(id: "second", toolName: "SECOND", arguments: "{}")
        }
        var session = OutputParserSession([.tool(ToolCallTransform(markers: [first, second]))])
        let events = runWhole(&session, "<call>body</call>")
        XCTAssertEqual(toolCalls(events).map(\.toolName), ["FIRST"])
    }

    // MARK: - Adversarial byte-boundary splitting

    /// Coalesces adjacent same-kind `.token` / `.thinkingToken` events into one,
    /// leaving every other event (`.thinkingCompleted`, `.toolCall`, …) as a
    /// boundary. Two `.token` fragments produced only because a chunk split mid
    /// visible text are semantically identical to one merged `.token` — the
    /// chunk-invariance property is about *content and routing*, not how many
    /// events the stream happened to be sliced into.
    private func coalesce(_ events: [GenerationEvent]) -> [GenerationEvent] {
        var out: [GenerationEvent] = []
        for event in events {
            switch (out.last, event) {
            case (.token(let a), .token(let b)):
                out[out.count - 1] = .token(a + b)
            case (.thinkingToken(let a), .thinkingToken(let b)):
                out[out.count - 1] = .thinkingToken(a + b)
            default:
                out.append(event)
            }
        }
        return out
    }

    /// Replays `input` split at EVERY character boundary and asserts the
    /// coalesced (ingest-per-piece + finalize) output is invariant to where the
    /// split lands — proving no marker leaks and no event is misrouted no matter
    /// where the boundary falls. Splitting on `Character` boundaries (not raw
    /// UTF-8 scalars) guarantees we never feed a mid-codepoint fragment.
    private func assertChunkInvariant(
        _ makeSession: () -> OutputParserSession,
        _ input: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Reference: whole input in one chunk, coalesced.
        var ref = makeSession()
        let reference = coalesce(ref.ingest(input) + ref.finalize())

        let chars = Array(input)
        for split in 0...chars.count {
            var session = makeSession()
            var events: [GenerationEvent] = []
            let head = String(chars[0..<split])
            let tail = String(chars[split..<chars.count])
            events += session.ingest(head)
            events += session.ingest(tail)
            events += session.finalize()
            XCTAssertEqual(coalesce(events), reference,
                "Output must be invariant to a split at character offset \(split)",
                file: file, line: line)
        }
    }

    func test_chunkInvariant_thinkingAndTool() {
        let input = "pre<think>cot</think>mid<tool_call>{\"name\":\"f\"}</tool_call>post"
        assertChunkInvariant(
            { self.makeSession(thinkingThenTool: true, tool: [self.jsonMarker()]) },
            input
        )
    }

    func test_chunkInvariant_twoCandidateEarliestOpen() {
        // The two open tags share a leading "<", so a split mid-prefix must not
        // misclassify the dialect or leak a partial tag.
        let input = "a[[call]]t1[[/call]]b<tool_call>{\"name\":\"t2\"}</tool_call>c"
        assertChunkInvariant(
            { self.makeSession(thinkingThenTool: true, tool: [self.bracketMarker(), self.jsonMarker()]) },
            input
        )
    }

    func test_chunkInvariant_multibyteUTF8_neverSplitMidCodepoint() {
        // Emoji + CJK around markers — character-boundary splitting must keep
        // grapheme clusters intact.
        let input = "héllo😀<think>思考</think>世界<tool_call>{\"name\":\"f\"}</tool_call>🚀"
        assertChunkInvariant(
            { self.makeSession(thinkingThenTool: true, tool: [self.jsonMarker()]) },
            input
        )
    }

    // MARK: - finalize() flush + sabotage

    func test_finalize_unterminatedThinking_flushesAsThinkingToken() {
        var session = makeSession(thinkingThenTool: true, tool: [jsonMarker()])
        var events = session.ingest("<think>unclosed reasoning")
        events += session.finalize()

        XCTAssertEqual(thinking(events), "unclosed reasoning")
        XCTAssertEqual(visible(events), "")
        // Sabotage: a finalize that emitted .token would leak reasoning as
        // visible text; this asserts it stays thinking.
    }

    func test_finalize_trailingPartialOpenTag_flushesAsToken() {
        var session = makeSession(thinkingThenTool: true, tool: [jsonMarker()])
        // Ends with a partial `<tool_call>` prefix held back at the boundary.
        var events = session.ingest("answer<tool_c")
        events += session.finalize()

        XCTAssertEqual(visible(events), "answer<tool_c")
        XCTAssertTrue(toolCalls(events).isEmpty)
    }

    func test_finalize_unterminatedToolBlock_isDiscarded() {
        var session = makeSession(thinkingThenTool: true, tool: [jsonMarker()])
        var events = session.ingest("text<tool_call>{\"name\":\"f\",\"arg")
        events += session.finalize()

        XCTAssertTrue(toolCalls(events).isEmpty,
            "An unterminated tool block must be discarded — partial body cannot form a ToolCall")
        XCTAssertEqual(visible(events), "text",
            "Visible text before the open tag is preserved; the dangling body is dropped")
    }

    func test_finalize_partialOpenTagFlushed_throughThinkingStage() {
        // A partial open tool tag held back by the tool stage at finalize must
        // still flow through... in Llama order [thinking, tool] the tool stage
        // is downstream, so its finalize text is terminal; in MLX order
        // [tool, thinking] the tool stage finalizes first and its text is then
        // scanned by thinking. Either way the text survives.
        var mlx = makeSession(thinkingThenTool: false, tool: [jsonMarker()])
        var events = mlx.ingest("done<tool_c")
        events += mlx.finalize()
        XCTAssertEqual(visible(events), "done<tool_c")
    }

    // MARK: - Body-size cap (DoS guard)

    func test_oversizedToolBody_withoutClose_isDroppedAndParserRecovers() {
        var transform = ToolCallTransform(markers: [jsonMarker()])
        // Open a tool block then stream a body far larger than the 256 KB cap
        // with no matching close tag (a truncated/adversarial stream).
        var events = transform.process([.token("<tool_call>")])
        events += transform.process([.token(String(repeating: "x", count: 300 * 1024))])

        // The oversized, unclosed body must be discarded — never handed to
        // parseBody — and no ToolCall is emitted.
        XCTAssertTrue(toolCalls(events).isEmpty,
            "An unbounded unclosed tool body must be dropped, not parsed")

        // After dropping, the parser must be back outside a block: a subsequent
        // well-formed call is parsed normally rather than being swallowed.
        var recovery = transform.process([.token("<tool_call>{\"name\":\"f\"}</tool_call>")])
        recovery += transform.finalize()
        XCTAssertEqual(toolCalls(recovery).map(\.toolName), ["f"],
            "Parser must recover and parse a valid call after dropping an oversized body")
    }
}
