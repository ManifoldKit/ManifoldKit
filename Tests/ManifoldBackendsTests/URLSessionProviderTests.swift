import XCTest
@testable import ManifoldBackends
@testable import ManifoldCloudCore
import ManifoldInference

final class URLSessionProviderTests: XCTestCase {

    func test_pinnedSession_hasExpectedTimeouts() {
        let session = URLSessionProvider.pinned
        // Sabotage check: changing timeoutIntervalForRequest in URLSessionProvider causes this to fail
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 300,
                       "Pinned session request timeout should be 300s")
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 600,
                       "Pinned session resource timeout should be 600s")
    }

    // PR #1138: pinned sessions now wrap PinnedSessionDelegate +
    // RedirectGuardDelegate inside a CompositeURLSessionDelegate, so the
    // session.delegate is the composite — not PinnedSessionDelegate directly.
    // The pinned-vs-unpinned shape is now distinguished by whether the
    // composite carries a serverTrustHandler that is a PinnedSessionDelegate.
    func test_pinnedSession_hasPinnedDelegateInChain() {
        let session = URLSessionProvider.pinned
        // Sabotage check: removing the serverTrustHandler argument from the
        // _pinned composite causes serverTrustHandler to be nil.
        let composite = session.delegate as? CompositeURLSessionDelegate
        XCTAssertNotNil(composite,
                        "Pinned session should use CompositeURLSessionDelegate")
        XCTAssertTrue(composite?.serverTrustHandler is PinnedSessionDelegate,
                      "Pinned session composite should carry a PinnedSessionDelegate as serverTrustHandler")
        // Redirect guard is always present on every composite — assert it
        // here so the test catches a regression that strips it from pinned.
        XCTAssertNotNil(composite?.redirectGuard,
                        "Pinned session composite should always carry a RedirectGuardDelegate")
    }

    func test_unpinnedSession_hasExpectedTimeouts() {
        let session = URLSessionProvider.unpinned
        // Sabotage check: changing timeoutIntervalForRequest in URLSessionProvider causes this to fail
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 300,
                       "Unpinned session request timeout should be 300s")
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 600,
                       "Unpinned session resource timeout should be 600s")
    }

    // PR #1138: the unpinned session previously had no delegate. It now
    // wraps RedirectGuardDelegate in a CompositeURLSessionDelegate so the
    // redirect-cap / scheme-downgrade / cross-origin header strip policy
    // fires on LAN endpoints too. Pinned-vs-unpinned is now distinguished
    // by the *contents* of the composite (serverTrustHandler nil vs a
    // PinnedSessionDelegate), not by whether a delegate exists at all.
    func test_unpinnedSession_hasRedirectGuardDelegate() {
        let session = URLSessionProvider.unpinned
        // Sabotage check: removing the composite from _unpinned causes the
        // cast to fail and the test to fail.
        let composite = session.delegate as? CompositeURLSessionDelegate
        XCTAssertNotNil(composite,
                        "Unpinned session should use CompositeURLSessionDelegate so the redirect guard fires on LAN endpoints")
        XCTAssertNotNil(composite?.redirectGuard,
                        "Unpinned composite must carry a RedirectGuardDelegate")
        // Sabotage check: assigning a PinnedSessionDelegate to the unpinned
        // composite's serverTrustHandler causes this to fail. Unpinned must
        // never carry pinning.
        XCTAssertNil(composite?.serverTrustHandler,
                     "Unpinned session composite must not carry a serverTrustHandler — pinning is reserved for the pinned session")
    }

    func test_pinnedAndUnpinned_areDifferentInstances() {
        // Sabotage check: returning the same session instance for both causes this to fail
        XCTAssertFalse(URLSessionProvider.pinned === URLSessionProvider.unpinned,
                       "Pinned and unpinned sessions should be different instances")
    }
}
