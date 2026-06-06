import XCTest
@testable import ManifoldHardware

final class DeviceCapabilityServiceTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private func makeService(ramGB: UInt64) -> DeviceCapabilityService {
        DeviceCapabilityService(physicalMemory: ramGB * oneGB)
    }

    // MARK: - recommendedModelSize

    func test_recommendedModelSize_6GBDevice_returnsSmall() {
        XCTAssertEqual(makeService(ramGB: 6).recommendedModelSize(), .small)
    }

    func test_recommendedModelSize_8GBDevice_returnsMedium() {
        XCTAssertEqual(makeService(ramGB: 8).recommendedModelSize(), .medium)
    }

    func test_recommendedModelSize_16GBDevice_returnsLarge() {
        XCTAssertEqual(makeService(ramGB: 16).recommendedModelSize(), .large)
    }

    func test_recommendedModelSize_32GBDevice_returnsXLarge() {
        XCTAssertEqual(makeService(ramGB: 32).recommendedModelSize(), .xlarge)
    }

    // MARK: - deviceDescription

    func test_deviceDescription_contains_correctRAMValue() {
        let description = makeService(ramGB: 16).deviceDescription
        XCTAssertTrue(description.contains("16 GB RAM"),
                      "Expected '16 GB RAM' in description, got: \(description)")
    }
}
