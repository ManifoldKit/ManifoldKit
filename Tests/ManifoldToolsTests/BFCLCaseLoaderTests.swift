import XCTest
@testable import ManifoldTools
import ManifoldInference

/// Coverage for loading BFCL cases from the bundled `simple` slice and mapping
/// the on-disk wire shape into the normalized domain types the matcher consumes.
final class BFCLCaseLoaderTests: XCTestCase {

    // MARK: - Bundled load

    func test_loadBundledSimple_returnsSortedCases() throws {
        let cases = try BFCLCaseLoader.loadBundledSimple()
        XCTAssertEqual(cases.count, 8, "the vendored simple slice has 8 cases")
        XCTAssertEqual(cases.map(\.id), cases.map(\.id).sorted(), "cases must be id-sorted for stable output")
        XCTAssertEqual(cases.first?.id, "simple_0")
    }

    func test_loadBundledSimple_mapsPromptToolsAndGroundTruth() throws {
        let cases = try BFCLCaseLoader.loadBundledSimple()
        let add = try XCTUnwrap(cases.first { $0.id == "simple_1" })

        XCTAssertTrue(add.prompt.contains("17 plus 4"), "prompt flattened from the user turn")
        XCTAssertEqual(add.tools.count, 1)
        XCTAssertEqual(add.tools.first?.name, "add")
        XCTAssertEqual(add.groundTruth.count, 1)
        XCTAssertEqual(add.groundTruth.first?.functionName, "add")
        XCTAssertEqual(add.groundTruth.first?.requiredParams, ["a", "b"])
    }

    func test_loadBundledSimple_derivesOptionalParamFromGroundTruth() throws {
        let cases = try BFCLCaseLoader.loadBundledSimple()
        let triangle = try XCTUnwrap(cases.first { $0.id == "simple_0" })
        // `unit` carries "" in its accepted list → optional; base/height required.
        XCTAssertEqual(triangle.groundTruth.first?.requiredParams, ["base", "height"])
    }

    func test_loadBundledSimple_normalizesDictTypeToObject() throws {
        let cases = try BFCLCaseLoader.loadBundledSimple()
        let add = try XCTUnwrap(cases.first { $0.id == "simple_1" })
        let params = try XCTUnwrap(add.tools.first?.parameters)
        guard case .object(let schema) = params else {
            return XCTFail("tool parameters should map to a JSON-Schema object, got \(params)")
        }
        // BFCL's `"type":"dict"` must be rewritten to JSON-Schema `"object"`.
        XCTAssertEqual(schema["type"], .string("object"), "the BFCL 'dict' type must be normalized to 'object'")
    }

    func test_loadBundledMultiple_loadsRealSliceWithDistractors() throws {
        // The `multiple` slice is a verbatim 25-case subset of upstream
        // BFCL_v4_multiple — several candidate functions per case, one correct.
        let cases = try BFCLCaseLoader.loadBundled(category: "multiple")
        XCTAssertEqual(cases.count, 25)
        // At least some case advertises >1 candidate function (the distractor
        // pressure that distinguishes `multiple` from `simple`).
        XCTAssertTrue(cases.contains { $0.tools.count > 1 }, "multiple cases advertise candidate functions")
        // Dotted (namespaced) function names must survive the mapping verbatim —
        // they are what the model is asked to call.
        XCTAssertTrue(
            cases.contains { c in c.groundTruth.contains { $0.functionName.contains(".") } },
            "BFCL multiple uses dot-namespaced function names"
        )
    }

    // MARK: - End-to-end compose (fixtures + loader + matcher)

    func test_everyBundledCase_matchesItsOwnGroundTruth() throws {
        // Synthesize the "perfect" call for each case from its own ground truth,
        // then confirm the matcher scores it correct. This pins fixtures + loader
        // + matcher together: a broken mapping or a fixture typo fails here.
        let cases = try BFCLCaseLoader.loadBundledSimple()
        for testCase in cases {
            let expected = try XCTUnwrap(testCase.groundTruth.first)
            let toolCall = ToolCall(
                id: "synthetic",
                toolName: expected.functionName,
                arguments: try perfectArguments(for: expected)
            )
            let score = ASTMatcher.scoreCase(emittedCalls: [toolCall], groundTruth: testCase.groundTruth)
            XCTAssertTrue(score.matched, "case \(testCase.id) should match its own ground truth: \(score.bestFailures)")
        }
    }

    // MARK: - Wire decoding

    func test_answerRecord_decodesAndFlattensGroundTruth() throws {
        let line = #"{"id":"x","ground_truth":[{"add":{"a":[17],"b":[4]}}]}"#
        let record = try JSONDecoder().decode(BFCLAnswerRecord.self, from: Data(line.utf8))
        let calls = record.expectedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.functionName, "add")
        XCTAssertEqual(calls.first?.requiredParams, ["a", "b"])
        XCTAssertEqual(calls.first?.acceptedValues["a"], [.integer(17)])
    }

    func test_questionRecord_decodesAndMapsToToolDefinition() throws {
        let line = #"{"id":"y","question":[[{"role":"user","content":"hi"}]],"function":[{"name":"f","description":"d","parameters":{"type":"dict","properties":{"x":{"type":"integer"}},"required":["x"]}}]}"#
        let record = try JSONDecoder().decode(BFCLQuestionRecord.self, from: Data(line.utf8))
        XCTAssertEqual(record.flattenedPrompt(), "hi")
        let tool = try XCTUnwrap(record.function.first?.toToolDefinition())
        XCTAssertEqual(tool.name, "f")
        guard case .object(let schema) = tool.parameters else {
            return XCTFail("expected object schema")
        }
        XCTAssertEqual(schema["type"], .string("object"))
    }

    // MARK: - Lockstep guard

    func test_load_missingAnswer_throws() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bfcl-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let questions = dir.appendingPathComponent("q.jsonl")
        let answers = dir.appendingPathComponent("a.jsonl")
        // A question with no matching answer id must fail loudly, not drop silently.
        try #"{"id":"orphan","question":[[{"role":"user","content":"hi"}]],"function":[]}"#
            .write(to: questions, atomically: true, encoding: .utf8)
        try "".write(to: answers, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try BFCLCaseLoader.load(questionsFile: questions, answersFile: answers)) { error in
            guard case BFCLCaseLoader.LoadError.answerMissing(let id) = error else {
                return XCTFail("expected answerMissing, got \(error)")
            }
            XCTAssertEqual(id, "orphan")
        }
    }

    // MARK: - Helpers

    /// Builds a JSON argument payload that satisfies an expected call by taking the
    /// first non-optional accepted value for each required parameter.
    private func perfectArguments(for expected: BFCLExpectedCall) throws -> String {
        var dict: [String: JSONSchemaValue] = [:]
        for param in expected.requiredParams {
            let accepted = expected.acceptedValues[param] ?? []
            if let first = accepted.first(where: { $0 != .string("") }) {
                dict[param] = first
            }
        }
        let data = try JSONEncoder().encode(dict)
        return String(decoding: data, as: UTF8.self)
    }
}
