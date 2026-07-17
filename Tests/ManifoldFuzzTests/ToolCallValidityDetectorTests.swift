import XCTest
@testable import ManifoldFuzz
import ManifoldInference

final class ToolCallValidityDetectorTests: XCTestCase {

    private func makeRecord(
        toolCalls: [ToolCall] = [],
        toolResults: [ToolResult] = [],
        toolDefinitions: [ToolDefinition] = SyntheticToolset.definitions,
        toolChoice: String? = "auto"
    ) -> RunRecord {
        RunRecord(
            runId: "test-run",
            ts: "2026-04-27T00:00:00Z",
            harness: .init(
                fuzzVersion: "0.0.0-test",
                packageGitRev: "deadbeef",
                packageGitDirty: false,
                swiftVersion: "6.1",
                osBuild: "test",
                thermalState: "nominal"
            ),
            model: .init(
                backend: "mock",
                id: "tool-validity-test",
                url: "mem://test",
                fileSHA256: nil,
                tokenizerHash: nil
            ),
            config: .init(
                seed: 0,
                temperature: 0.0,
                topP: 1.0,
                maxTokens: nil,
                systemPrompt: nil,
                toolChoice: toolChoice
            ),
            prompt: .init(
                corpusId: "tool-validity-test",
                mutators: [],
                messages: [.init(role: "user", text: "what is the weather in london?")]
            ),
            events: [],
            raw: "",
            rendered: "",
            thinkingRaw: "",
            thinkingParts: [],
            thinkingCompleteCount: 0,
            templateMarkers: nil,
            memory: .init(beforeBytes: nil, peakBytes: nil, afterBytes: nil),
            timing: .init(firstTokenMs: nil, totalMs: 0, tokensPerSec: nil),
            phase: "done",
            error: nil,
            stopReason: "naturalStop",
            toolCalls: toolCalls,
            toolResults: toolResults,
            toolDefinitions: toolDefinitions
        )
    }

    // MARK: - orphan-result (issue's headline case)

    func test_orphanResult_fires_whenResultReferencesUnknownCallId() {
        let r = makeRecord(
            toolCalls: [
                ToolCall(id: "call_1", toolName: "get_weather", arguments: #"{"city":"London"}"#)
            ],
            toolResults: [
                ToolResult(callId: "call_1", content: "sunny"),
                ToolResult(callId: "call_phantom", content: "??"),
            ]
        )
        let findings = ToolCallValidityDetector().inspect(r)
        XCTAssertTrue(findings.contains { $0.subCheck == "orphan-result" },
                      "expected orphan-result to fire on unknown callId")
    }

    func test_cleanRun_producesNoFindings() {
        let r = makeRecord(
            toolCalls: [
                ToolCall(id: "call_1", toolName: "get_weather", arguments: #"{"city":"London","units":"metric"}"#)
            ],
            toolResults: [
                ToolResult(callId: "call_1", content: "sunny")
            ]
        )
        let findings = ToolCallValidityDetector().inspect(r)
        XCTAssertEqual(findings, [], "clean run should produce no findings; got: \(findings.map(\.subCheck))")
    }

    // MARK: - malformed-json-args

    func test_malformedJSONArgs_fires_whenArgumentsAreNotJSON() {
        let r = makeRecord(
            toolCalls: [
                ToolCall(id: "c1", toolName: "get_weather", arguments: "city=London")
            ]
        )
        let findings = ToolCallValidityDetector().inspect(r)
        XCTAssertTrue(findings.contains { $0.subCheck == "malformed-json-args" })
    }

    // MARK: - schema-violation

    func test_schemaViolation_fires_whenRequiredFieldMissing() {
        let r = makeRecord(
            toolCalls: [
                ToolCall(id: "c1", toolName: "get_weather", arguments: #"{"units":"metric"}"#)
            ]
        )
        let findings = ToolCallValidityDetector().inspect(r)
        XCTAssertTrue(findings.contains { $0.subCheck == "schema-violation" })
    }

    // MARK: - unknown-tool-name

    func test_unknownToolName_fires_whenToolNameNotDeclared() {
        let r = makeRecord(
            toolCalls: [
                ToolCall(id: "c1", toolName: "definitely_not_a_real_tool", arguments: #"{"foo":"bar"}"#)
            ]
        )
        let findings = ToolCallValidityDetector().inspect(r)
        XCTAssertEqual(findings.filter { $0.subCheck == "unknown-tool-name" }.count, 1,
                        "expected exactly one unknown-tool-name finding; got: \(findings.map(\.subCheck))")
    }

    func test_unknownToolName_doesNotFire_forDeclaredToolWithValidArgs() {
        let r = makeRecord(
            toolCalls: [
                ToolCall(id: "c1", toolName: "get_weather", arguments: #"{"city":"London","units":"metric"}"#)
            ]
        )
        let findings = ToolCallValidityDetector().inspect(r)
        XCTAssertFalse(findings.contains { $0.subCheck == "unknown-tool-name" },
                        "known tool with valid args must not trip unknown-tool-name")
    }

    // MARK: - id-reuse

    func test_idReuse_fires_whenSameCallIdAppearsTwice() {
        let r = makeRecord(
            toolCalls: [
                ToolCall(id: "dup", toolName: "get_weather", arguments: #"{"city":"London"}"#),
                ToolCall(id: "dup", toolName: "get_weather", arguments: #"{"city":"Paris"}"#),
            ]
        )
        let findings = ToolCallValidityDetector().inspect(r)
        XCTAssertTrue(findings.contains { $0.subCheck == "id-reuse" })
    }

    // MARK: - toolchoice-violation

    func test_toolchoiceViolation_fires_whenRequiredProducesZeroCalls() {
        let r = makeRecord(toolCalls: [], toolChoice: "required")
        let findings = ToolCallValidityDetector().inspect(r)
        XCTAssertTrue(findings.contains { $0.subCheck == "toolchoice-violation" })
    }

    func test_toolchoiceViolation_fires_whenNoneProducesCalls() {
        let r = makeRecord(
            toolCalls: [
                ToolCall(id: "c1", toolName: "get_weather", arguments: #"{"city":"London"}"#)
            ],
            toolChoice: "none"
        )
        let findings = ToolCallValidityDetector().inspect(r)
        XCTAssertTrue(findings.contains { $0.subCheck == "toolchoice-violation" })
    }

    func test_toolchoiceViolation_fires_whenForcedToolProducesZeroCalls() {
        // A backend that silently drops a forced-tool selection must not look
        // clean to this sub-check.
        let r = makeRecord(toolCalls: [], toolChoice: "tool:get_weather")
        let findings = ToolCallValidityDetector().inspect(r)
        XCTAssertTrue(findings.contains { $0.subCheck == "toolchoice-violation" },
                      "expected toolchoice-violation for forced tool with zero calls")
    }

    func test_duplicateToolDefinitions_doNotTrap() {
        // Replayed/hand-edited records can carry duplicate tool names; the
        // detector must tolerate them rather than crashing the fuzz run.
        let dup = SyntheticToolset.definitions + SyntheticToolset.definitions
        let r = makeRecord(
            toolCalls: [
                ToolCall(id: "c1", toolName: "get_weather", arguments: #"{"city":"London","units":"metric"}"#)
            ],
            toolDefinitions: dup
        )
        let findings = ToolCallValidityDetector().inspect(r)
        XCTAssertEqual(findings, [], "duplicate tool defs must not produce findings on a clean call")
    }

    func test_toolchoiceViolation_fires_whenToolNameMismatch() {
        let r = makeRecord(
            toolCalls: [
                ToolCall(id: "c1", toolName: "get_weather", arguments: #"{"city":"London"}"#)
            ],
            toolChoice: "tool:schedule_alarm"
        )
        let findings = ToolCallValidityDetector().inspect(r)
        XCTAssertTrue(findings.contains { $0.subCheck == "toolchoice-violation" })
    }

    // MARK: - severity

    func test_subCheckSeverityPolicy_pinsConfirmedAndFlakySplit() {
        // Pins the day-one severity policy:
        //   confirmed — id-reuse, orphan-result (zero-FP-by-construction)
        //   flaky    — malformed-json-args, schema-violation,
        //              unknown-tool-name, toolchoice-violation
        //              (decode/prompt-drift; calibration tracked under #488)
        // Bumping or downgrading either bucket without updating the policy is
        // a real product change and should land deliberately, not silently.
        let r = makeRecord(
            toolCalls: [
                ToolCall(id: "c1", toolName: "get_weather", arguments: "not json"),
                ToolCall(id: "c1", toolName: "get_weather", arguments: #"{"city":"London"}"#),
            ],
            toolResults: [
                ToolResult(callId: "phantom", content: "")
            ],
            toolChoice: "none"
        )
        let findings = ToolCallValidityDetector().inspect(r)
        XCTAssertFalse(findings.isEmpty)

        let confirmedSubChecks: Set<String> = ["id-reuse", "orphan-result"]
        let flakySubChecks: Set<String> = [
            "malformed-json-args",
            "schema-violation",
            "unknown-tool-name",
            "toolchoice-violation",
        ]
        for f in findings {
            if confirmedSubChecks.contains(f.subCheck) {
                XCTAssertEqual(f.severity, .confirmed,
                               "deterministic invariant \(f.subCheck) must ship .confirmed")
            } else if flakySubChecks.contains(f.subCheck) {
                XCTAssertEqual(f.severity, .flaky,
                               "calibration-pending \(f.subCheck) must ship .flaky until #488 settles")
            } else {
                XCTFail("unknown sub-check \(f.subCheck) — severity policy un-pinned")
            }
        }
    }

    // MARK: - registry

    func test_detectorRegistered_inAll() {
        XCTAssertTrue(DetectorRegistry.all.contains { $0.id == "tool-call-validity" })
    }
}
