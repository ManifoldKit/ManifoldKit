import XCTest
@testable import ManifoldInference

final class VideoGenerationTests: XCTestCase {

    // MARK: - ImageModelFormat

    func test_imageModelFormat_includesCloudAPI() {
        XCTAssertTrue(
            ImageModelFormat.allCases.contains(.cloudAPI),
            "ImageModelFormat.cloudAPI must be present in allCases"
        )
    }

    func test_imageModelFormat_cloudAPI_codableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(ImageModelFormat.cloudAPI)
        let decoded = try JSONDecoder().decode(ImageModelFormat.self, from: encoded)
        XCTAssertEqual(decoded, .cloudAPI)
        let rawString = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertEqual(rawString, "\"cloudAPI\"")
    }

    // MARK: - VideoGenerationConfig

    func test_videoGenerationConfig_defaults() {
        let config = VideoGenerationConfig()
        XCTAssertEqual(config.duration, 5)
        XCTAssertEqual(config.aspectRatio, VideoGenerationConfig.AspectRatio.landscape)
        XCTAssertNil(config.width)
        XCTAssertNil(config.height)
        XCTAssertNil(config.sourceImageURL)
    }

    func test_videoGenerationConfig_durationPassedThrough() {
        // Backends enforce their own limits; the config stores the value as-is.
        XCTAssertEqual(VideoGenerationConfig(duration: 0).duration, 0)
        XCTAssertEqual(VideoGenerationConfig(duration: 7).duration, 7)
        XCTAssertEqual(VideoGenerationConfig(duration: 100).duration, 100)
    }

    func test_videoGenerationConfig_codableRoundTrip() throws {
        let config = VideoGenerationConfig(
            duration: 8,
            aspectRatio: VideoGenerationConfig.AspectRatio.portrait,
            width: 1280,
            height: 720,
            sourceImageURL: URL(fileURLWithPath: "/tmp/source.jpg")
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(VideoGenerationConfig.self, from: data)
        XCTAssertEqual(decoded.duration, config.duration)
        XCTAssertEqual(decoded.aspectRatio, config.aspectRatio)
        XCTAssertEqual(decoded.width, config.width)
        XCTAssertEqual(decoded.height, config.height)
        XCTAssertEqual(decoded.sourceImageURL, config.sourceImageURL)
    }

    func test_videoGenerationConfig_acceptsArbitraryAspectRatioString() {
        // AspectRatio is a free-form string; backends that use non-standard
        // notation (e.g. "LANDSCAPE") can pass any value.
        let custom = VideoGenerationConfig(aspectRatio: "WIDESCREEN")
        XCTAssertEqual(custom.aspectRatio, "WIDESCREEN")
    }

    // MARK: - AspectRatio constants

    func test_aspectRatio_constantValues() {
        XCTAssertEqual(VideoGenerationConfig.AspectRatio.landscape, "16:9")
        XCTAssertEqual(VideoGenerationConfig.AspectRatio.portrait,  "9:16")
        XCTAssertEqual(VideoGenerationConfig.AspectRatio.square,    "1:1")
        XCTAssertEqual(VideoGenerationConfig.AspectRatio.wide,      "4:3")
        XCTAssertEqual(VideoGenerationConfig.AspectRatio.tall,      "3:4")
    }

    // MARK: - VideoGenerationEvent

    func test_videoGenerationEvent_codableRoundTrip() throws {
        let events: [VideoGenerationEvent] = [
            .queued,
            .generating(fractionComplete: 0.42),
            .completed(URL(fileURLWithPath: "/tmp/output.mp4"))
        ]
        for event in events {
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(VideoGenerationEvent.self, from: data)
            switch (event, decoded) {
            case (.queued, .queued): break
            case (.generating(let a), .generating(let b)):
                XCTAssertEqual(a, b, accuracy: 0.001)
            case (.completed(let a), .completed(let b)):
                XCTAssertEqual(a, b)
            default:
                XCTFail("Round-trip mismatch: \(event) → \(decoded)")
            }
        }
    }
}
