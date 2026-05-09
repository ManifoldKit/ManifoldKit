import XCTest
import ManifoldTestSupport
@testable import ManifoldInference

final class HotPathPerformanceTests: XCTestCase {

    private static let sessionID = UUID()

    // MARK: - trimMessages (100+ messages, mixed lengths)

    func testPerf_trimMessages_mixedLengths() {
        let shortContent = "Quick reply."
        let mediumContent = String(repeating: "This is a medium-length message. ", count: 10)
        let longContent = String(repeating: "This is a longer message with more content to process. ", count: 50)

        let messages: [ChatMessageRecord] = (0..<200).map { i in
            let role: MessageRole = i % 2 == 0 ? .user : .assistant
            let content: String
            switch i % 3 {
            case 0: content = shortContent
            case 1: content = mediumContent
            default: content = longContent
            }
            return ChatMessageRecord(role: role, content: content, sessionID: Self.sessionID)
        }
        let systemPrompt = "You are a helpful assistant that provides detailed answers."

        measure {
            _ = ContextWindowManager.trimMessages(
                messages,
                systemPrompt: systemPrompt,
                maxTokens: 4096,
                responseBuffer: 512
            )
        }
    }

    // MARK: - SSEStreamParser (1000+ tokens)

    func testPerf_sseStreamParser_1000tokens() async throws {
        var ssePayload = ""
        for i in 0..<1200 {
            let json = #"{"choices":[{"delta":{"content":"token\#(i) "}}]}"#
            ssePayload += "data: \(json)\n\n"
        }
        ssePayload += "data: [DONE]\n\n"
        let sseData = Array(ssePayload.utf8)

        measure {
            let expectation = self.expectation(description: "stream")
            Task {
                let byteStream = AsyncThrowingStream<UInt8, Error> { continuation in
                    for byte in sseData {
                        continuation.yield(byte)
                    }
                    continuation.finish()
                }
                let stream = SSEStreamParser.parse(bytes: byteStream)
                var count = 0
                for try await _ in stream {
                    count += 1
                }
                expectation.fulfill()
            }
            self.wait(for: [expectation], timeout: 5)
        }
    }

    // MARK: - ModelStorageService.discoverModels (populated directory)

    private var service: ModelStorageService!
    private var scratchDirectory: URL!
    private var createdURLs: [URL] = []

    override func setUp() {
        super.setUp()
        // Isolate perf fixtures from the user's real Documents/Models path.
        // `measure { }` runs the closure many times, so leaks here compound
        // quickly — see #379.
        let isolated = makeIsolatedModelStorage()
        service = isolated.service
        scratchDirectory = isolated.directory
        createdURLs = []
    }

    override func tearDown() {
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: scratchDirectory)
        createdURLs = []
        scratchDirectory = nil
        service = nil
        super.tearDown()
    }

    @discardableResult
    private func createGgufFile(named prefix: String, size: Int = 512) throws -> URL {
        try service.ensureModelsDirectory()
        let fileName = "\(prefix)-\(UUID().uuidString).gguf"
        let url = service.modelsDirectory.appendingPathComponent(fileName)
        try Data(repeating: 0xAA, count: size).write(to: url)
        createdURLs.append(url)
        return url
    }

    @discardableResult
    private func createMlxDirectory(named prefix: String) throws -> URL {
        try service.ensureModelsDirectory()
        let dirName = "\(prefix)-\(UUID().uuidString)"
        let url = service.modelsDirectory.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url.appendingPathComponent("config.json"))
        try Data(repeating: 0xBB, count: 1024).write(to: url.appendingPathComponent("weights.safetensors"))
        createdURLs.append(url)
        return url
    }

    func testPerf_discoverModels_populatedDirectory() throws {
        for i in 0..<15 {
            try createGgufFile(named: "perf-gguf-\(i)")
        }
        for i in 0..<5 {
            try createMlxDirectory(named: "perf-mlx-\(i)")
        }

        measure {
            _ = service.discoverModels()
        }
    }

    // MARK: - HeuristicTokenizer.estimateTokenCount (long inputs)

    func testPerf_heuristicTokenizer_longRealisticInput() {
        let paragraph = "The quick brown fox jumps over the lazy dog. "
        let longInput = String(repeating: paragraph, count: 2000)
        let tokenizer = HeuristicTokenizer()

        measure {
            _ = tokenizer.tokenCount(longInput)
        }
    }

    func testPerf_heuristicTokenizer_100kChars() {
        let longInput = String(repeating: "abcdefghij", count: 10_000)
        let tokenizer = HeuristicTokenizer()

        measure {
            _ = tokenizer.tokenCount(longInput)
        }
    }
}
