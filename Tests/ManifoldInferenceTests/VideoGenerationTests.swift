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

    func test_videoGenerationConfig_durationClampedToRange() {
        XCTAssertEqual(VideoGenerationConfig(duration: 0).duration, 1)
        XCTAssertEqual(VideoGenerationConfig(duration: -10).duration, 1)
        XCTAssertEqual(VideoGenerationConfig(duration: 16).duration, 15)
        XCTAssertEqual(VideoGenerationConfig(duration: 100).duration, 15)
        XCTAssertEqual(VideoGenerationConfig(duration: 7).duration, 7)
    }

    func test_videoGenerationConfig_codableRoundTrip() throws {
        let config = VideoGenerationConfig(
            duration: 8,
            aspectRatio: .portrait,
            resolution: .sd,
            sourceImageURL: URL(fileURLWithPath: "/tmp/source.jpg")
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(VideoGenerationConfig.self, from: data)
        XCTAssertEqual(decoded.duration, config.duration)
        XCTAssertEqual(decoded.aspectRatio, config.aspectRatio)
        XCTAssertEqual(decoded.resolution, config.resolution)
        XCTAssertEqual(decoded.sourceImageURL, config.sourceImageURL)
    }

    func test_videoGenerationConfig_defaults() {
        let config = VideoGenerationConfig()
        XCTAssertEqual(config.duration, 5)
        XCTAssertEqual(config.aspectRatio, .landscape)
        XCTAssertEqual(config.resolution, .hd)
        XCTAssertNil(config.sourceImageURL)
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

    // MARK: - AspectRatio / Resolution coverage

    func test_aspectRatio_allCasesHaveRawValue() {
        for ratio in VideoGenerationConfig.AspectRatio.allCases {
            XCTAssertFalse(ratio.rawValue.isEmpty)
        }
    }

    func test_resolution_allCasesHaveRawValue() {
        for res in VideoGenerationConfig.Resolution.allCases {
            XCTAssertFalse(res.rawValue.isEmpty)
        }
    }
}
