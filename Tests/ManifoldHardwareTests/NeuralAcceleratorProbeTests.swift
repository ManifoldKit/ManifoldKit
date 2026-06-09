import XCTest
@testable import ManifoldHardware

#if os(macOS)
final class NeuralAcceleratorProbeTests: XCTestCase {

    func testNeuralAcceleratorProbeReturnsValidCase() {
        let result = NeuralAcceleratorProbe.availability
        switch result {
        case .available, .unavailableHardware, .unavailableOS, .unsupportedPlatform:
            break  // all valid cases; cannot assert specific value in CI (no M5 runner)
        }
    }
}
#endif
