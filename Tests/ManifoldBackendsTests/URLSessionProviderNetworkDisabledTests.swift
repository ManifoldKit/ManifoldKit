import XCTest
import ManifoldInference
@testable import ManifoldFoundation
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore

/// Tests for the runtime kill-switch ``URLSessionProvider/networkDisabled``.
///
/// Belt-and-suspenders coverage for regulated runtimes that need to lock the
/// network even in a `full`-trait build. Setting `networkDisabled = true`
/// causes every factory (`pinned`, `unpinned`) to throw
/// ``CloudBackendError/networkDisabled`` rather than returning a session.
///
/// Sabotage check: comment out the `if networkDisabled { throw … }` guard at
/// the top of either factory and these tests fail.
final class URLSessionProviderNetworkDisabledTests: XCTestCase {

    override func tearDown() {
        // Always restore the global flag so other tests aren't affected.
        URLSessionProvider.networkDisabled = false
        super.tearDown()
    }

    func test_pinned_throws_whenNetworkDisabled() {
        URLSessionProvider.networkDisabled = true

        do {
            _ = try URLSessionProvider.throwingPinned()
            XCTFail("URLSessionProvider.throwingPinned() should throw when networkDisabled = true")
        } catch let error as CloudBackendError {
            switch error {
            case .networkDisabled: break
            default:
                XCTFail("Expected CloudBackendError.networkDisabled but got \(error)")
            }
        } catch {
            XCTFail("Expected CloudBackendError.networkDisabled but got \(error)")
        }
    }

    func test_pinned_returnsSession_whenNetworkEnabled() throws {
        URLSessionProvider.networkDisabled = false
        let session = try URLSessionProvider.throwingPinned()
        XCTAssertNotNil(session.delegate, "pinned session should still install its delegate when network is enabled")
    }

    func test_unpinned_throws_whenNetworkDisabled() {
        URLSessionProvider.networkDisabled = true

        do {
            _ = try URLSessionProvider.throwingUnpinned()
            XCTFail("URLSessionProvider.throwingUnpinned() should throw when networkDisabled = true")
        } catch let error as CloudBackendError {
            switch error {
            case .networkDisabled: break
            default:
                XCTFail("Expected CloudBackendError.networkDisabled but got \(error)")
            }
        } catch {
            XCTFail("Expected CloudBackendError.networkDisabled but got \(error)")
        }
    }

    func test_unpinned_returnsSession_whenNetworkEnabled() throws {
        URLSessionProvider.networkDisabled = false
        let session = try URLSessionProvider.throwingUnpinned()
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 300)
    }

    func test_killSwitch_propagates_throughOllamaBackendMakeChecked() throws {
        URLSessionProvider.networkDisabled = true
        do {
            _ = try OllamaBackend.makeChecked()
            XCTFail("OllamaBackend.makeChecked() should throw when networkDisabled = true and no urlSession is injected")
        } catch let error as CloudBackendError {
            switch error {
            case .networkDisabled: break
            default:
                XCTFail("Expected CloudBackendError.networkDisabled but got \(error)")
            }
        } catch {
            XCTFail("Expected CloudBackendError.networkDisabled but got \(error)")
        }
    }

    func test_killSwitch_propagates_throughOpenAIBackendMakeChecked() throws {
        URLSessionProvider.networkDisabled = true
        do {
            _ = try OpenAIBackend.makeChecked()
            XCTFail("OpenAIBackend.makeChecked() should throw when networkDisabled = true and no urlSession is injected")
        } catch let error as CloudBackendError {
            switch error {
            case .networkDisabled: break
            default:
                XCTFail("Expected CloudBackendError.networkDisabled but got \(error)")
            }
        } catch {
            XCTFail("Expected CloudBackendError.networkDisabled but got \(error)")
        }
    }

    func test_killSwitch_propagates_throughClaudeBackendMakeChecked() throws {
        URLSessionProvider.networkDisabled = true
        do {
            _ = try ClaudeBackend.makeChecked()
            XCTFail("ClaudeBackend.makeChecked() should throw when networkDisabled = true and no urlSession is injected")
        } catch let error as CloudBackendError {
            switch error {
            case .networkDisabled: break
            default:
                XCTFail("Expected CloudBackendError.networkDisabled but got \(error)")
            }
        } catch {
            XCTFail("Expected CloudBackendError.networkDisabled but got \(error)")
        }
    }

    // MARK: - Non-throwing accessors no longer trap (regression coverage)
    //
    // Before this fix, `URLSessionProvider.pinned`/`.unpinned` trapped the
    // process with a `precondition` when `networkDisabled` was set — so
    // merely constructing a cloud backend via its plain, non-`makeChecked`
    // convenience `init(urlSession:)` (the common, undocumented-as-risky
    // path) crashed the whole host app instead of failing the one request.
    // Sabotage check: reintroduce `precondition(!networkDisabled, ...)` in
    // either accessor and these tests crash the test process instead of
    // passing/failing normally.

    // The error thrown by `NetworkKillSwitchProtocol` round-trips through
    // URLSession's task machinery (even for an ephemeral in-process
    // session), which re-serializes it as a bridged `NSError` and does not
    // reliably reconstruct the original `CloudBackendError.networkDisabled`
    // Swift case on the other side of `data(for:)` — so these assertions
    // compare `NSError` domain/code against the same error's own bridged
    // representation instead of pattern-matching the Swift enum case.
    // What matters for this regression test is (a) no trap and (b) the
    // request never reaches the network — not the exact catch-site
    // ergonomics, which `throwingPinned()`/`throwingUnpinned()` already
    // cover with a direct (non-round-tripped) throw.

    func test_pinned_doesNotTrap_whenNetworkDisabled_andFailsFirstRequest() async throws {
        URLSessionProvider.networkDisabled = true
        // Must not trap merely by being accessed.
        let session = URLSessionProvider.pinned

        // A fake, UUID-namespaced, guaranteed-unresolvable host — never a
        // real provider hostname. `NetworkKillSwitchProtocol.canInit(with:)`
        // intercepts every request regardless of target, so this proves the
        // regression without risking real egress to a live API if the
        // interception were ever broken (found in review).
        let expected = CloudBackendError.networkDisabled as NSError
        let request = URLRequest(url: URL(string: "https://killswitch-\(UUID().uuidString).test/v1/messages")!)
        do {
            _ = try await session.data(for: request)
            XCTFail("Request through the poisoned session should fail, not reach the network")
        } catch {
            let ns = error as NSError
            XCTAssertEqual(ns.domain, expected.domain, "unexpected error domain: \(error)")
            XCTAssertEqual(ns.code, expected.code, "unexpected error code: \(error)")
        }
    }

    func test_unpinned_doesNotTrap_whenNetworkDisabled_andFailsFirstRequest() async throws {
        URLSessionProvider.networkDisabled = true
        let session = URLSessionProvider.unpinned

        // Fake host — see the comment in the `pinned` variant above.
        let expected = CloudBackendError.networkDisabled as NSError
        let request = URLRequest(url: URL(string: "http://killswitch-\(UUID().uuidString).test/api/generate")!)
        do {
            _ = try await session.data(for: request)
            XCTFail("Request through the poisoned session should fail, not reach the network")
        } catch {
            let ns = error as NSError
            XCTAssertEqual(ns.domain, expected.domain, "unexpected error domain: \(error)")
            XCTAssertEqual(ns.code, expected.code, "unexpected error code: \(error)")
        }
    }

    func test_claudeBackendPlainInit_doesNotTrap_whenNetworkDisabled() {
        URLSessionProvider.networkDisabled = true
        // The plain convenience init (not `makeChecked`) must not crash the
        // process just because the kill-switch is set — only a subsequent
        // request through the resulting backend fails.
        let backend = ClaudeBackend()
        XCTAssertNotNil(backend)
    }

    /// Locks in the design decision documented on `URLSessionProvider.pinned`
    /// (see "Design decision — deliberately NOT re-checked per request"):
    /// `pinned`/`unpinned` are resolved ONCE, at access time, exactly like
    /// every other injected `urlSession` in this codebase — a session
    /// obtained while the switch was `true` stays poisoned for its whole
    /// lifetime even after the switch flips back to `false`. This is not
    /// re-litigated by a future "helpful" change that makes the session
    /// dynamically re-check the switch per request without a deliberate
    /// design review (see the doc comment for why that's a bigger change).
    func test_pinned_staysPoisoned_afterNetworkDisabledFlipsBackOff() async throws {
        URLSessionProvider.networkDisabled = true
        let session = URLSessionProvider.pinned // captured while poisoned

        URLSessionProvider.networkDisabled = false // switch flips back off

        let request = URLRequest(url: URL(string: "https://killswitch-\(UUID().uuidString).test/v1/messages")!)
        do {
            _ = try await session.data(for: request)
            XCTFail("A session captured while the switch was set must stay poisoned even after the switch flips off")
        } catch {
            let ns = error as NSError
            let expected = CloudBackendError.networkDisabled as NSError
            XCTAssertEqual(ns.domain, expected.domain)
            XCTAssertEqual(ns.code, expected.code)
        }
    }
}
