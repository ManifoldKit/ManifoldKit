import XCTest
import SwiftUI
import ManifoldUIModelManagement

/// Pins the pre-#2476 import surface. `endpointStore` now lives in ManifoldUI
/// so ChatView can forward it across its presentation boundary, but apps that
/// previously imported only ManifoldUIModelManagement must keep compiling.
final class EndpointStoreImportCompatibilityTests: XCTestCase {
    func test_endpointStore_remainsAvailableFromModelManagementImport() {
        let environment = EnvironmentValues()
        XCTAssertNil(environment.endpointStore)
    }
}
