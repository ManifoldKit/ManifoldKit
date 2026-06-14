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
}
