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

    /// The environment is process-global, so these tests use one dedicated key
    /// and restore its prior state before returning to parallel test execution.
    private func withCaptureDirectory<T>(
        _ directory: URL,
        operation: () async throws -> T
    ) async rethrows -> T {
        let key = "MK_OVERNIGHT_CAPTURE_DIR"
        let original = ProcessInfo.processInfo.environment[key]
        setenv(key, directory.path, 1)
        defer {
            if let original {
                setenv(key, original, 1)
            } else {
                unsetenv(key)
            }
        }
        return try await operation()
    }

    func test_requestedArchiveWritesCleanSessionCapture() async throws {
        let outputDir = temporaryURL("output")
        let captureDir = temporaryURL("archive")
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: captureDir)
        }

        let report = try await withCaptureDirectory(captureDir) {
            await SessionFuzzRunner(config: config(outputDir: outputDir), factory: MockFactory(), scripts: [script()])
                .run(reporter: TerminalReporter(quiet: true))
        }

        XCTAssertEqual(report.totalRuns, 1)
        XCTAssertEqual(report.realCompletions, 1)
        XCTAssertFalse(report.isInert)

        let captureURL = captureDir.appendingPathComponent("capture-1.json")
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

        let report = try await withCaptureDirectory(occupiedPath) {
            await SessionFuzzRunner(config: config(outputDir: outputDir), factory: MockFactory(), scripts: [script()])
                .run(reporter: TerminalReporter(quiet: true))
        }

        XCTAssertEqual(report.totalRuns, 0, "a requested archive that cannot be written must fail rather than report a clean campaign")
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertEqual(report.realCompletions, 0)
    }
}
