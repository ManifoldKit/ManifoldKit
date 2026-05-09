@preconcurrency import XCTest
@testable import ManifoldUI

#if os(iOS)
@MainActor
final class ClipboardWriterTests: XCTestCase {
    func test_pasteboardOptions_useLocalOnlyAndExpiration() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let options = ClipboardWriter.pasteboardOptions(now: now)

        XCTAssertEqual(options[.localOnly] as? Bool, true)
        let expiration = options[.expirationDate] as? Date
        XCTAssertNotNil(expiration)
        XCTAssertEqual(
            expiration?.timeIntervalSince1970,
            now.addingTimeInterval(ClipboardWriter.expirationInterval).timeIntervalSince1970,
            accuracy: 0.001
        )
    }
}
#endif
