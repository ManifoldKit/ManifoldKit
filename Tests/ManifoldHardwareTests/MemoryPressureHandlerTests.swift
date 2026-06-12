import XCTest
@testable import ManifoldHardware
// BackendInternals SPI: seam published for the companion split (#1749).
@_spi(BackendInternals) import ManifoldHardware

final class MemoryPressureHandlerTests: XCTestCase {

    // MARK: - Initial State

    func test_initialPressureLevel_isNominal() {
        let handler = MemoryPressureHandler()
        XCTAssertEqual(handler.pressureLevel, .nominal)
    }

    // MARK: - Start Monitoring Idempotency

    func test_startMonitoring_calledTwice_doesNotCrash() {
        let handler = MemoryPressureHandler()
        handler.startMonitoring()
        handler.startMonitoring()
        // If we get here without crashing, the idempotency guard works.
        handler.stopMonitoring()
    }

    // MARK: - Stop Monitoring Safety

    func test_stopMonitoring_whenNotMonitoring_doesNotCrash() {
        let handler = MemoryPressureHandler()
        handler.stopMonitoring()
        handler.stopMonitoring()
        // Should be safe no-ops
    }

    // MARK: - Stop Then Start

    func test_stopThenStart_restartsCorrectly() {
        let handler = MemoryPressureHandler()

        handler.startMonitoring()
        handler.stopMonitoring()
        handler.startMonitoring()

        // Should still be nominal — restarting does not change the level
        XCTAssertEqual(handler.pressureLevel, .nominal)
        handler.stopMonitoring()
    }

    // MARK: - Deinit Safety

    func test_deinit_stopsMonitoringCleanly() {
        var handler: MemoryPressureHandler? = MemoryPressureHandler()
        handler?.startMonitoring()
        handler = nil
        // If we get here, deinit cleaned up without crashing
    }
}
