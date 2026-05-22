// QuickStartTests.swift
//
// Exercises `ManifoldKit.quickStart()` — the one-call facade that collapses
// the documented three-object bootstrap dance. The README's getting-started
// snippet depends on this returning a working `ChatViewModel` + bootstrap
// pair, and on errors surfacing through the unified `ManifoldKitError` rim
// rather than raw underlying errors.

import XCTest
import SwiftData
import ManifoldInference
import ManifoldPersistenceSwiftData
@testable import ManifoldKit

@MainActor
final class QuickStartTests: XCTestCase {

    /// The happy path: `quickStart()` returns a bootstrap and a view model
    /// that share the same inference service and have persistence wired up.
    ///
    /// We use the internal `_quickStart` seam with an in-memory SwiftData
    /// container so the test doesn't touch the on-disk Application Support
    /// store the default factory derives.
    func test_quickStart_returnsBootstrappedViewModel() async throws {
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        // Bootstrap side: every service the facade promises was constructed.
        // `ChatViewModel.inferenceService` is intentionally `internal` to
        // ManifoldUI (see CLAUDE.md "Service sharing"), so we can't assert
        // reference identity from this test target — instead we check that
        // the bootstrap exposes the shared services the view model was
        // configured against.
        XCTAssertNotNil(result.bootstrap.persistence)
        XCTAssertNotNil(result.bootstrap.conversationRuntime)
        XCTAssertNotNil(result.bootstrap.endpointStore)

        // View-model side: observable surface area is wired. `modelRegistry`
        // is the documented sibling-module read seam (CLAUDE.md "Service
        // sharing") and is populated from the inference service the
        // bootstrap built.
        XCTAssertNotNil(result.viewModel.modelRegistry)
    }

    /// Errors from any step in the bootstrap chain must be reduced through
    /// `ManifoldKitError.from(_:)` rather than leaking the raw underlying
    /// error. We force a failure by passing a throwing model-container
    /// factory and assert the caught error is `ManifoldKitError`.
    func test_quickStart_surfacesManifoldKitError_onFailure() async {
        struct ForcedFailure: Error {}

        do {
            _ = try await ManifoldKit._quickStart(
                configuration: .default,
                makeModelContainer: { throw ForcedFailure() }
            )
            XCTFail("quickStart() must throw when the model container factory throws.")
        } catch let error as ManifoldKitError {
            // Unknown errors fall through to .unknown — that's the expected
            // case for a synthetic test error that doesn't match any of the
            // structured URLError / DecodingError / KeychainError shapes.
            switch error {
            case .unknown:
                break
            default:
                XCTFail("Expected .unknown ManifoldKitError, got \(error).")
            }
        } catch {
            XCTFail("Expected ManifoldKitError, got \(type(of: error)): \(error). The facade must wrap all underlying errors through ManifoldKitError.from(_:).")
        }
    }

    /// Compile-time check that `QuickStartResult` is `Sendable`. The README's
    /// snippet stores the result in a `@State` property or passes it across
    /// task boundaries; losing Sendability would silently break that.
    func test_QuickStartResult_isSendable() {
        _requireSendable(QuickStartResult.self)
    }

    private func _requireSendable<T: Sendable>(_: T.Type) {}
}
