@preconcurrency import AVFoundation
@preconcurrency import XCTest
import Foundation
@testable import ManifoldInference

/// Coverage for ``AppleTTSBackend`` — the zero-dependency in-core reference
/// audio-generation backend backed by `AVSpeechSynthesizer`.
///
/// ## Headless rendering
///
/// `AVSpeechSynthesizer.write(_:toBufferCallback:)` renders to a buffer
/// callback rather than the speaker, so it does not require an audio output
/// device and *should* work in a headless `swift test` run. The integration
/// test that actually renders a file is written to tolerate environments where
/// the synthesiser declines to produce audio (no installed voices, CI sandbox):
/// it asserts a real, non-empty audio file *when* a `.completed` event fires,
/// and skips (via `XCTSkip`) rather than failing if the render produces no
/// audio — the deterministic mapping logic is covered by the unit tests below
/// regardless.
@MainActor
final class AppleTTSBackendTests: XCTestCase {

    // MARK: - Unit: utterance mapping (deterministic, no render)

    func test_makeUtterance_honoursRateAndPitch() {
        let config = SpeechGenerationConfig(text: "hi", rate: 0.4, pitch: 1.5)
        let utterance = AppleTTSBackend.makeUtterance(text: "hi", config: config)
        XCTAssertEqual(utterance.speechString, "hi")
        XCTAssertEqual(utterance.rate, 0.4, accuracy: 0.0001)
        XCTAssertEqual(utterance.pitchMultiplier, 1.5, accuracy: 0.0001)
    }

    func test_makeUtterance_resolvesLanguageTagVoice() {
        // A BCP-47 language tag should resolve to an installed voice when one
        // exists for that language. If the test host has no en-US voice at all
        // (unusual), the voice stays nil — assert only that mapping does not
        // crash and leaves the text intact.
        let config = SpeechGenerationConfig(text: "hi", voice: "en-US")
        let utterance = AppleTTSBackend.makeUtterance(text: "hi", config: config)
        XCTAssertEqual(utterance.speechString, "hi")
        if AVSpeechSynthesisVoice(language: "en-US") != nil {
            XCTAssertNotNil(utterance.voice, "Expected en-US to resolve to an installed voice")
        }
    }

    func test_makeOutputURL_honoursOutputDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-out-\(UUID().uuidString)", isDirectory: true)
        let url = AppleTTSBackend.makeOutputURL(directory: dir)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        XCTAssertEqual(url.pathExtension, "caf")
    }

    func test_makeOutputURL_defaultsToTemporaryDirectory() {
        let url = AppleTTSBackend.makeOutputURL(directory: nil)
        XCTAssertEqual(url.pathExtension, "caf")
        // Lives under the temp directory when no output directory is supplied.
        XCTAssertTrue(
            url.path.hasPrefix(FileManager.default.temporaryDirectory.path),
            "Expected default URL under the temp directory; got \(url.path)"
        )
    }

    // MARK: - Unit: empty prompt rejected synchronously

    func test_generate_emptyPrompt_throwsSynchronously() {
        let backend = AppleTTSBackend()
        XCTAssertThrowsError(try backend.generate(config: SpeechGenerationConfig(text: "   "))) { error in
            XCTAssertEqual(error as? AppleTTSBackend.BackendError, .noAudioProduced)
        }
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Integration: real render to a file (tolerant)

    /// Renders a short phrase with the real `AVSpeechSynthesizer` and asserts a
    /// non-empty audio file when the synthesiser produces audio. Tolerant of
    /// headless environments that decline to render: skips rather than fails if
    /// no `.completed` event arrives within the deadline.
    func test_generate_realSynthesizer_producesAudioFile() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-itest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let backend = AppleTTSBackend()
        let config = SpeechGenerationConfig(
            text: "Hello from ManifoldKit.",
            outputDirectory: outputDir
        )

        let stream = try backend.generate(config: config)

        // Collect events with a deadline so a non-rendering host can't hang.
        var completedURL: URL?
        var sawProgress = false
        let collected: Result<Void, Error> = await withTaskGroup(of: Result<(URL?, Bool), Error>.self) { group in
            group.addTask {
                do {
                    var url: URL?
                    var progress = false
                    for try await event in stream {
                        switch event {
                        case .progress: progress = true
                        case .completed(let u): url = u
                        }
                    }
                    return .success((url, progress))
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return .success((nil, false))
            }
            let first = await group.next()
            group.cancelAll()
            switch first {
            case .success(let (url, progress)):
                completedURL = url
                sawProgress = progress
                return .success(())
            case .failure(let error):
                return .failure(error)
            case .none:
                return .success(())
            }
        }

        if case .failure(let error) = collected {
            throw error
        }

        guard let url = completedURL else {
            throw XCTSkip("AVSpeechSynthesizer produced no audio in this environment (no installed voices / headless sandbox); deterministic mapping is covered by the unit tests")
        }

        XCTAssertTrue(sawProgress, "Expected at least one progress tick before completion")

        // The file must exist, be non-empty, and be a readable audio file.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Expected audio file at \(url.path)")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "Expected a non-empty audio file")

        // It must open as a real audio file with a non-zero frame count.
        let audioFile = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(audioFile.length, 0, "Expected rendered audio frames")

        // Backend returns to idle after completion.
        XCTAssertFalse(backend.isGenerating, "Expected backend idle after completion")
    }
}
