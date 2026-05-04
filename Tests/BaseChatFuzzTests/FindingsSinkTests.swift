#if Fuzz
import XCTest
@testable import BaseChatFuzz

final class FindingsSinkTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BaseChatFuzzTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func makeRecord(modelId: String = "test-model") -> RunRecord {
        RunRecord(
            runId: UUID().uuidString,
            ts: "2026-04-19T00:00:00Z",
            harness: .init(
                fuzzVersion: "0.0.0-test",
                packageGitRev: "deadbeef",
                packageGitDirty: false,
                swiftVersion: "6.1",
                osBuild: "test",
                thermalState: "nominal"
            ),
            model: .init(backend: "mock", id: modelId, url: "mem://test", fileSHA256: nil, tokenizerHash: nil),
            config: .init(seed: 0, temperature: 0.0, topP: 1.0, maxTokens: nil, systemPrompt: nil),
            prompt: .init(corpusId: "test", mutators: [], messages: []),
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
            error: nil
        )
    }

    private func makeFinding(subCheck: String = "sub", trigger: String = "trig", modelId: String = "test-model") -> Finding {
        Finding(detectorId: "det", subCheck: subCheck, severity: .flaky, trigger: trigger, modelId: modelId)
    }

    func test_recordRun_writesRecordAndReproForSingleFinding() async throws {
        let sink = FindingsSink(outputDir: tempDir)
        let finding = makeFinding()
        await sink.recordRun(makeRecord(modelId: "qwen-test"), findings: [finding])

        let dir = tempDir
            .appendingPathComponent("findings")
            .appendingPathComponent("det")
            .appendingPathComponent(finding.hash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("record.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("repro.sh").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.txt").path))

        let repro = try String(contentsOf: dir.appendingPathComponent("repro.sh"), encoding: .utf8)
        let executableLines = repro
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertTrue(
            executableLines.contains(where: { $0.contains("--replay \(finding.hash)") }),
            "--replay is the preferred repro recipe (#490); seed/model variant lives as a commented fallback"
        )
        XCTAssertTrue(repro.contains("--output-dir '\(tempDir.path)'"))
        // The commented fallback still references the original seed/model pair so the
        // developer can bypass replay if a rev bump invalidates the record.
        XCTAssertTrue(repro.contains("--seed 0"))
        XCTAssertTrue(repro.contains("--model qwen-test"))
        XCTAssertTrue(repro.contains("--single"))
    }

    func test_recordRun_dedupesIdenticalFindings_andProducesOneDirectory() async throws {
        let sink = FindingsSink(outputDir: tempDir)
        let finding = makeFinding()
        await sink.recordRun(makeRecord(), findings: [finding])
        await sink.recordRun(makeRecord(), findings: [finding])

        let snap = await sink.snapshot()
        XCTAssertEqual(snap.totalRuns, 2)
        XCTAssertEqual(snap.findings.count, 1)
        XCTAssertEqual(snap.findings.first?.count, 2)

        let detDir = tempDir.appendingPathComponent("findings").appendingPathComponent("det")
        let entries = try FileManager.default.contentsOfDirectory(atPath: detDir.path)
        XCTAssertEqual(entries.count, 1, "duplicate finding must reuse the same hash directory")
    }

    func test_recordRun_distinctTriggers_produceTwoDirectories() async throws {
        let sink = FindingsSink(outputDir: tempDir)
        let a = makeFinding(trigger: "alpha")
        let b = makeFinding(trigger: "beta")
        XCTAssertNotEqual(a.hash, b.hash, "different triggers must hash differently")

        await sink.recordRun(makeRecord(), findings: [a, b])

        let detDir = tempDir.appendingPathComponent("findings").appendingPathComponent("det")
        let entries = try FileManager.default.contentsOfDirectory(atPath: detDir.path).sorted()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains(a.hash))
        XCTAssertTrue(entries.contains(b.hash))
    }

    func test_indexMarkdown_isRegeneratedAndContainsHashAndReproCommand() async throws {
        let sink = FindingsSink(outputDir: tempDir)
        let finding = makeFinding(trigger: "indexable-trigger")
        await sink.recordRun(makeRecord(modelId: "indexed-model"), findings: [finding])

        let indexURL = tempDir.appendingPathComponent("INDEX.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
        let md = try String(contentsOf: indexURL, encoding: .utf8)
        XCTAssertTrue(md.contains("`\(finding.hash)`"))
        XCTAssertTrue(md.contains("swift run fuzz-chat --replay \(finding.hash)"))
        XCTAssertTrue(md.contains("--output-dir '\(tempDir.path)'"))
        XCTAssertTrue(md.contains("1 total runs"))

        await sink.recordRun(makeRecord(modelId: "indexed-model"), findings: [finding])
        let md2 = try String(contentsOf: indexURL, encoding: .utf8)
        XCTAssertTrue(md2.contains("2 total runs"), "INDEX.md must regenerate on every flush")
    }

    func test_secondSinkAtSameOutputDir_readsExistingIndex() async throws {
        let first = FindingsSink(outputDir: tempDir)
        let finding = makeFinding(trigger: "persisted")
        await first.recordRun(makeRecord(), findings: [finding])
        await first.noteEmptyRun()
        await first.noteEmptyRun()

        let second = FindingsSink(outputDir: tempDir)
        let snap = await second.snapshot()
        XCTAssertEqual(snap.findings.count, 1)
        XCTAssertEqual(snap.findings.first?.hash, finding.hash)
        XCTAssertEqual(snap.totalRuns, 3, "totalRuns must persist across sink instances")
    }

    func test_recordRun_doesNotOverwriteFirstSeenRecord() async throws {
        let sink = FindingsSink(outputDir: tempDir)
        let finding = makeFinding(trigger: "stable-trigger")
        let firstRecord = makeRecord(modelId: "first-run")
        await sink.recordRun(firstRecord, findings: [finding])

        let secondRecord = makeRecord(modelId: "second-run")
        await sink.recordRun(secondRecord, findings: [finding])

        let recordURL = tempDir
            .appendingPathComponent("findings")
            .appendingPathComponent("det")
            .appendingPathComponent(finding.hash)
            .appendingPathComponent("record.json")
        let data = try Data(contentsOf: recordURL)
        let decoded = try JSONDecoder().decode(RunRecord.self, from: data)
        XCTAssertEqual(decoded.runId, firstRecord.runId, "first-seen record.json must not be overwritten on subsequent hits")
        XCTAssertEqual(decoded.model.id, "first-run")
    }

    func test_noteEmptyRun_writesIndexEvenWithoutFindings() async throws {
        let sink = FindingsSink(outputDir: tempDir)
        await sink.noteEmptyRun()
        await sink.noteEmptyRun()

        let snap = await sink.snapshot()
        XCTAssertEqual(snap.totalRuns, 2)
        XCTAssertEqual(snap.findings.count, 0)

        let indexURL = tempDir.appendingPathComponent("INDEX.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
        let md = try String(contentsOf: indexURL, encoding: .utf8)
        XCTAssertTrue(md.contains("2 total runs"))
    }
}
#endif
