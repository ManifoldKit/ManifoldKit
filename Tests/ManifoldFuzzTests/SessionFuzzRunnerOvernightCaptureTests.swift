import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldFuzz

/// Covers the opt-in archive used by overnight session campaigns. FindingsSink
/// stores only flagged runs, while this archive must retain clean captures too.
final class SessionFuzzRunnerOvernightCaptureTests: XCTestCase {

    private struct MockFactory: FuzzBackendFactory {
        @MainActor
        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            let backend = MockInferenceBackend()
            backend.tokensToYield = ["captured"]
            try await backend.loadModel(from: URL(string: "mock:mock-model")!, plan: .cloud())
            return FuzzRunner.BackendHandle(
                backend: backend,
                modelId: "mock-model",
                modelURL: URL(string: "mock:mock-model")!,
                backendName: "mock",
                templateMarkers: nil
            )
        }
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("session-fuzz-overnight-capture-\(name)-\(UUID().uuidString)")
    }

    private func script() -> SessionScript {
        SessionScript(id: "overnight-capture", steps: [.send(text: "Capture this run.")])
    }

    private func config(outputDir: URL) -> FuzzConfig {
        FuzzConfig(
            backend: .mock,
            iterations: 1,
            seed: 1,
            outputDir: outputDir,
            quiet: true,
            sessionScripts: true
        )
    }

    private func runner(outputDir: URL, captureDir: URL) -> SessionFuzzRunner {
        SessionFuzzRunner(
            config: config(outputDir: outputDir),
            factory: MockFactory(),
            scripts: [script()],
            overnightCaptureDirectory: captureDir.path
        )
    }

    func test_requestedArchiveWritesCleanSessionCapture() async throws {
        let outputDir = temporaryURL("output")
        let captureDir = temporaryURL("archive")
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: captureDir)
        }

        let report = await runner(outputDir: outputDir, captureDir: captureDir)
            .run(reporter: TerminalReporter(quiet: true))

        XCTAssertEqual(report.totalRuns, 1)
        XCTAssertEqual(report.realCompletions, 1)
        XCTAssertFalse(report.isInert)

        let captureURL = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: captureDir, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.hasPrefix("capture-1-") })
        )
        let data = try Data(contentsOf: captureURL)
        let snapshot = try JSONDecoder().decode(SessionCaptureSnapshot.self, from: data)
        XCTAssertEqual(snapshot.script.id, "overnight-capture")
        XCTAssertEqual(snapshot.steps.count, 1)
        XCTAssertEqual(snapshot.steps.first?.record?.raw, "captured")
    }

    func test_requestedArchiveWriteFailureFailsCampaign() async throws {
        let outputDir = temporaryURL("output")
        let occupiedPath = temporaryURL("occupied")
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: occupiedPath)
        }
        try Data("not a directory".utf8).write(to: occupiedPath)

        let report = await runner(outputDir: outputDir, captureDir: occupiedPath)
            .run(reporter: TerminalReporter(quiet: true))

        XCTAssertEqual(report.totalRuns, 0, "a requested archive that cannot be written must fail rather than report a clean campaign")
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertEqual(report.realCompletions, 0)
    }

    func test_concurrentRunnersArchiveDistinctCapturesWithoutOverwriting() async throws {
        let outputA = temporaryURL("output-a")
        let outputB = temporaryURL("output-b")
        let captureDir = temporaryURL("shared-archive")
        defer {
            try? FileManager.default.removeItem(at: outputA)
            try? FileManager.default.removeItem(at: outputB)
            try? FileManager.default.removeItem(at: captureDir)
        }

        let runnerA = runner(outputDir: outputA, captureDir: captureDir)
        let runnerB = runner(outputDir: outputB, captureDir: captureDir)
        async let reportA = runnerA.run(reporter: TerminalReporter(quiet: true))
        async let reportB = runnerB.run(reporter: TerminalReporter(quiet: true))
        let (first, second) = await (reportA, reportB)

        XCTAssertEqual(first.totalRuns, 1)
        XCTAssertEqual(second.totalRuns, 1)
        let captures = try FileManager.default.contentsOfDirectory(at: captureDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("capture-1-") }
        XCTAssertEqual(captures.count, 2, "each concurrent runner must retain its own iteration-one evidence")
        XCTAssertEqual(Set(captures.map(\.lastPathComponent)).count, 2)
    }
}
