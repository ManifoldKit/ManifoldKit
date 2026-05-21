#if Ollama || CloudSaaS
import XCTest
@testable import ManifoldCloudCore
import ManifoldInference

// MARK: - URLSessionProviderContract
//
// Contract mixin for ``URLSessionProvider`` behavior.
//
// ``URLSessionProvider`` is a concrete enum (not a protocol), so this file
// ships as an adopter test class rather than a protocol mixin. It exercises
// the documented behavioral invariants of the provider that any alternative
// session factory must also satisfy, and validates the security-critical
// properties of the sessions it vends.
//
// Any embedder that wraps or replaces ``URLSessionProvider`` can adopt the
// ``URLSessionProviderContract`` protocol below to validate the same
// invariants against their own implementation.

/// Opt-in XCTestCase mixin for custom ``URLSession`` factory implementations.
///
/// Adopt this on a test class to run the behavioral contract checks that
/// ``URLSessionProvider`` satisfies. This lets embedders who swap in a
/// custom factory (e.g. for testing or regulation) verify their replacement
/// meets the same security and correctness bar.
///
/// ```swift
/// final class MySessionFactoryContractTests: XCTestCase, URLSessionProviderContract {
///     func makeSession() -> URLSession { MySessionFactory.shared.session }
///     func makeSession(identifier: String) -> URLSession { MySessionFactory.background(id: identifier) }
/// }
/// ```
protocol URLSessionProviderContract: AnyObject {
    /// Returns the session under test (the unpinned / default session for
    /// implementations that don't distinguish pinned/unpinned).
    func makeSession() -> URLSession

    /// Returns a background session with the given identifier.
    func makeBackgroundSession(identifier: String) -> URLSession
}

extension URLSessionProviderContract where Self: XCTestCase {

    /// Asserts the session uses a reasonable request timeout (> 0 seconds).
    func assertURLSession_requestTimeoutIsPositive(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let session = makeSession()
        XCTAssertGreaterThan(
            session.configuration.timeoutIntervalForRequest,
            0,
            "Session request timeout must be > 0",
            file: file, line: line
        )
    }

    /// Asserts the session uses a reasonable resource timeout (> 0 seconds).
    func assertURLSession_resourceTimeoutIsPositive(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let session = makeSession()
        XCTAssertGreaterThan(
            session.configuration.timeoutIntervalForResource,
            0,
            "Session resource timeout must be > 0",
            file: file, line: line
        )
    }

    /// Asserts a background session is returned without crashing.
    func assertURLSession_backgroundSessionIsNonNil(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let session = makeBackgroundSession(identifier: "com.manifoldkit.contract.test.\(UUID().uuidString)")
        XCTAssertNotNil(session, "background() must return a URLSession", file: file, line: line)
    }
}

// MARK: - URLSessionProviderContractTests

/// Exercises the behavioral contract of ``URLSessionProvider`` itself.
final class URLSessionProviderContractTests: XCTestCase, URLSessionProviderContract {

    func makeSession() -> URLSession {
        URLSessionProvider.unpinned
    }

    func makeBackgroundSession(identifier: String) -> URLSession {
        URLSessionProvider.background(identifier: identifier)
    }

    // MARK: - Contract adoption

    func test_requestTimeout_isPositive() {
        assertURLSession_requestTimeoutIsPositive()
    }

    func test_resourceTimeout_isPositive() {
        assertURLSession_resourceTimeoutIsPositive()
    }

    func test_backgroundSession_isNonNil() {
        assertURLSession_backgroundSessionIsNonNil()
    }

    // MARK: - Security invariants specific to URLSessionProvider

    /// The unpinned session must carry a ``CompositeURLSessionDelegate`` whose
    /// ``redirectGuard`` is non-nil — the redirect policy is the minimum
    /// security bar for all sessions.
    func test_unpinnedSession_carresRedirectGuardDelegate() {
        let session = URLSessionProvider.unpinned
        let composite = session.delegate as? CompositeURLSessionDelegate
        XCTAssertNotNil(
            composite,
            "Unpinned session must use CompositeURLSessionDelegate"
        )
        XCTAssertNotNil(
            composite?.redirectGuard,
            "Unpinned session composite must carry a RedirectGuardDelegate"
        )
    }

    /// ``networkDisabled`` defaults to `false` so sessions are available
    /// at startup without any configuration.
    func test_networkDisabled_defaultsToFalse() {
        XCTAssertFalse(
            URLSessionProvider.networkDisabled,
            "networkDisabled must default to false"
        )
    }

    /// ``defaultHopCap`` must be positive to allow normal redirects.
    func test_defaultHopCap_isPositive() {
        XCTAssertGreaterThan(
            URLSessionProvider.defaultHopCap,
            0,
            "defaultHopCap must be > 0"
        )
    }

    #if CloudSaaS
    /// The pinned session must differ from the unpinned session (they serve
    /// distinct trust policies).
    func test_pinnedAndUnpinned_areDifferentObjects() {
        XCTAssertFalse(
            URLSessionProvider.pinned === URLSessionProvider.unpinned,
            "pinned and unpinned sessions must be different objects"
        )
    }

    /// The pinned session's composite must carry a serverTrustHandler.
    func test_pinnedSession_carresPinnedSessionDelegate() {
        let composite = URLSessionProvider.pinned.delegate as? CompositeURLSessionDelegate
        XCTAssertNotNil(composite, "Pinned session must use CompositeURLSessionDelegate")
        XCTAssertTrue(
            composite?.serverTrustHandler is PinnedSessionDelegate,
            "Pinned session composite must carry a PinnedSessionDelegate"
        )
    }
    #endif
}
#endif
