import Foundation

/// A `URLProtocol` subclass that **denies every network request unconditionally**
/// and records each attempt for later assertion.
///
/// Distinct from ``MockURLProtocol``, which intercepts only when stubs are
/// registered. `DenyAllURLProtocol.canInit(with:)` always returns `true`, so it
/// catches **any** outbound request — including unstubbed ones that
/// `MockURLProtocol` would let pass through to the real network.
///
/// ## Why a separate type
///
/// `LocalOnlyNetworkIsolationTests` needs a load-bearing guarantee: in a build
/// configured for local-only inference, **zero** outbound requests should occur
/// during a full chat flow. Reusing `MockURLProtocol` is unsafe — its
/// `canInit` returns `false` when no stubs are registered, so a regression that
/// adds an unstubbed `URLSession.shared.dataTask(...)` would silently escape
/// to the real network and the test would still pass.
///
/// ## Coverage seam
///
/// `URLProtocol.registerClass(_:)` is process-global, but `URLSession`
/// consults that registry only for `URLSession.shared`. Custom sessions
/// constructed via `URLSession(configuration:)` only see protocols listed in
/// the configuration's own `protocolClasses` array.
///
/// To cover both cases:
/// - ``register()`` calls `URLProtocol.registerClass` so any code that uses
///   `URLSession.shared` (including transitive-dep static initializers) is
///   intercepted.
/// - ``installedConfiguration(base:)`` and ``installedSession(base:)`` return
///   a configuration / session with the protocol explicitly prepended. Tests
///   that build their own `URLSession(configuration:)` must inject through
///   these helpers to be observed.
///
/// ## Usage
///
/// ```swift
/// override func setUp() {
///     super.setUp()
///     DenyAllURLProtocol.reset()
///     DenyAllURLProtocol.register()
/// }
///
/// override func tearDown() {
///     DenyAllURLProtocol.unregister()
///     XCTAssertFalse(
///         DenyAllURLProtocol.didAttemptRequest,
///         "Unexpected outbound network: \(DenyAllURLProtocol.attemptedRequests)"
///     )
///     super.tearDown()
/// }
///
/// func test_localBackend_makesNoNetworkCalls() async throws {
///     // For a backend that constructs its own URLSession, inject via the
///     // installedSession helper so the canary is visible to it.
///     let session = DenyAllURLProtocol.installedSession()
///     let backend = SomeBackend(urlSession: session)
///     try await backend.run()
///     // tearDown's assertion catches any leak.
/// }
/// ```
public final class DenyAllURLProtocol: URLProtocol {

    // MARK: - State

    private static let lock = NSLock()
    private nonisolated(unsafe) static var _attemptedRequests: [URLRequest] = []
    private nonisolated(unsafe) static var _registeredCount = 0

    /// All requests intercepted since the last ``reset()`` call, in order.
    public static var attemptedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _attemptedRequests
    }

    /// Convenience: `true` iff at least one request was attempted since reset.
    public static var didAttemptRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !_attemptedRequests.isEmpty
    }

    /// Clears the attempt log. Call in `setUp` before each test.
    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        _attemptedRequests.removeAll()
    }

    // MARK: - Registration

    /// Registers the protocol globally so `URLSession.shared` and any session
    /// using the default protocol classes inherit the canary.
    ///
    /// Reference-counted: nested `register()` / `unregister()` pairs are safe.
    /// The protocol stays registered until the outermost `unregister()` call.
    public static func register() {
        lock.lock()
        defer { lock.unlock() }
        if _registeredCount == 0 {
            URLProtocol.registerClass(DenyAllURLProtocol.self)
        }
        _registeredCount += 1
    }

    /// Decrements the registration count. When the count reaches zero,
    /// removes the protocol from the global registry.
    public static func unregister() {
        lock.lock()
        defer { lock.unlock() }
        guard _registeredCount > 0 else { return }
        _registeredCount -= 1
        if _registeredCount == 0 {
            URLProtocol.unregisterClass(DenyAllURLProtocol.self)
        }
    }

    // MARK: - Custom-session injection

    /// Returns a `URLSessionConfiguration` with `DenyAllURLProtocol` prepended
    /// to `protocolClasses`.
    ///
    /// `URLSession(configuration:)` does not consult `URLProtocol.registerClass`,
    /// so any custom session built for tests must use a configuration produced
    /// by this helper — otherwise the canary will not see its requests.
    ///
    /// - Parameter base: The starting configuration. Defaults to `.ephemeral`.
    ///   The returned configuration is a defensive copy — `base` is not
    ///   mutated, even when callers pass a configuration they share elsewhere.
    public static func installedConfiguration(
        base: URLSessionConfiguration = .ephemeral
    ) -> URLSessionConfiguration {
        // URLSessionConfiguration is a reference type — copy before mutating
        // so callers who pass their own configuration aren't surprised by
        // in-place changes.
        let config = base.copy() as! URLSessionConfiguration
        var classes = config.protocolClasses ?? []
        classes.insert(DenyAllURLProtocol.self, at: 0)
        config.protocolClasses = classes
        return config
    }

    /// Convenience: a `URLSession` whose configuration has the canary installed.
    public static func installedSession(
        base: URLSessionConfiguration = .ephemeral
    ) -> URLSession {
        URLSession(configuration: installedConfiguration(base: base))
    }

    // MARK: - URLProtocol Overrides

    public override class func canInit(with request: URLRequest) -> Bool {
        // Unconditional — every outbound URLSession request must be observed.
        true
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        Self.lock.lock()
        Self._attemptedRequests.append(request)
        Self.lock.unlock()

        // Fail the request with a recognisable error so a backend doesn't hang
        // waiting for a response while the test inspects the attempt log.
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    public override func stopLoading() {
        // No-op — startLoading completes synchronously.
    }
}
