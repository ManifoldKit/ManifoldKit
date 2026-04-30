import XCTest
@testable import BaseChatRuntime
@testable import BaseChatInference

/// Phase 1.2 sub-step 2 — coverage for the passive-merge use case.
///
/// Each test exercises a single behavioural property: provider count,
/// per-provider order independence, error propagation, tie-breaking, and
/// `messageCount` plumbing. Sabotage notes per test were verified locally
/// (temporarily breaking the assertion target made the test fail) and removed
/// before commit, per CLAUDE.md test conventions.
final class PromptContextPipelineTests: XCTestCase {

    // MARK: - Fakes

    /// In-test conformer that returns a fixed slot list. Records the
    /// `messageCount` it was called with so tests can assert plumbing.
    private struct FakeProvider: PromptContextProvider {
        let slots: [PromptSlot]
        let receivedCount: SendableBox<Int?>

        init(slots: [PromptSlot], receivedCount: SendableBox<Int?> = .init(nil)) {
            self.slots = slots
            self.receivedCount = receivedCount
        }

        func contributeSlots(messageCount: Int) async throws -> [PromptSlot] {
            receivedCount.value = messageCount
            return slots
        }
    }

    /// Provider that always throws. Used to assert error propagation.
    private struct ThrowingProvider: PromptContextProvider {
        struct Boom: Error, Equatable {}
        func contributeSlots(messageCount: Int) async throws -> [PromptSlot] {
            throw Boom()
        }
    }

    /// `Sendable` reference cell for capturing call arguments out of a
    /// `Sendable` provider value type. The test runs single-threaded, so a
    /// plain class with a mutable property is safe under `@unchecked`.
    private final class SendableBox<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: - Helpers

    private func slot(
        id: String,
        position: PromptSlotPosition,
        content: String = "x"
    ) -> PromptSlot {
        PromptSlot(
            id: id,
            content: content,
            position: position,
            label: id
        )
    }

    // MARK: - Tests

    func test_singleProvider_returnsItsSlotsSortedByPosition() async throws {
        let bottom = slot(id: "bottom", position: .bottomOfHistory)
        let top = slot(id: "top", position: .systemPreamble)
        let middle = slot(id: "middle", position: .contextSetup)

        let provider = FakeProvider(slots: [bottom, top, middle])
        let pipeline = PromptContextPipeline(providers: [provider])

        let result = try await pipeline.assemble(messageCount: 3)

        XCTAssertEqual(result.map(\.id), ["top", "middle", "bottom"])
    }

    func test_multipleProviders_concatenateAndSortByPosition() async throws {
        let p1 = FakeProvider(slots: [
            slot(id: "p1-bottom", position: .bottomOfHistory),
            slot(id: "p1-system", position: .systemPreamble),
        ])
        let p2 = FakeProvider(slots: [
            slot(id: "p2-context", position: .contextSetup),
            slot(id: "p2-inline", position: .inline),
        ])

        let pipeline = PromptContextPipeline(providers: [p1, p2])
        let result = try await pipeline.assemble(messageCount: 5)

        XCTAssertEqual(
            result.map(\.id),
            ["p1-system", "p2-context", "p1-bottom", "p2-inline"]
        )
    }

    func test_providerOrder_doesNotAffectFinalOrderWhenPositionsDisagree() async throws {
        let pA = FakeProvider(slots: [slot(id: "system", position: .systemPreamble)])
        let pB = FakeProvider(slots: [slot(id: "context", position: .contextSetup)])

        let resultAB = try await PromptContextPipeline(providers: [pA, pB])
            .assemble(messageCount: 2)
        let resultBA = try await PromptContextPipeline(providers: [pB, pA])
            .assemble(messageCount: 2)

        XCTAssertEqual(resultAB.map(\.id), ["system", "context"])
        XCTAssertEqual(resultBA.map(\.id), ["system", "context"])
    }

    func test_emptyProvider_returnsUnionOfOthers() async throws {
        let empty = FakeProvider(slots: [])
        let real = FakeProvider(slots: [
            slot(id: "a", position: .systemPreamble),
            slot(id: "b", position: .contextSetup),
        ])

        let pipeline = PromptContextPipeline(providers: [empty, real, empty])
        let result = try await pipeline.assemble(messageCount: 0)

        XCTAssertEqual(result.map(\.id), ["a", "b"])
    }

    func test_emptyPipeline_returnsEmpty() async throws {
        let pipeline = PromptContextPipeline(providers: [])
        let result = try await pipeline.assemble(messageCount: 7)
        XCTAssertTrue(result.isEmpty)
    }

    func test_providerThrows_pipelinePropagatesAndDoesNotReturnPartial() async {
        let before = FakeProvider(slots: [slot(id: "before", position: .systemPreamble)])
        let throwing = ThrowingProvider()
        let after = FakeProvider(slots: [slot(id: "after", position: .inline)])

        let pipeline = PromptContextPipeline(providers: [before, throwing, after])

        do {
            _ = try await pipeline.assemble(messageCount: 1)
            XCTFail("expected pipeline to throw")
        } catch let error as ThrowingProvider.Boom {
            // Expected: the specific error from the failing provider propagates.
            _ = error
        } catch {
            XCTFail("expected ThrowingProvider.Boom; got \(error)")
        }
    }

    func test_positionTieBreak_isStableInProviderOrder() async throws {
        // Two slots at the same position from a single provider should keep
        // their input-array order. `Array.sorted(by:)` is documented stable
        // on Swift 5+, but the brief says to lock the actual behaviour rather
        // than over-specify.
        let p1 = FakeProvider(slots: [
            slot(id: "p1-first", position: .contextSetup),
            slot(id: "p1-second", position: .contextSetup),
        ])
        let p2 = FakeProvider(slots: [
            slot(id: "p2-first", position: .contextSetup),
        ])

        let pipeline = PromptContextPipeline(providers: [p1, p2])
        let result = try await pipeline.assemble(messageCount: 3)

        XCTAssertEqual(
            result.map(\.id),
            ["p1-first", "p1-second", "p2-first"]
        )
    }

    func test_messageCount_flowsToProviders() async throws {
        let captureA = SendableBox<Int?>(nil)
        let captureB = SendableBox<Int?>(nil)

        let pA = FakeProvider(slots: [], receivedCount: captureA)
        let pB = FakeProvider(slots: [], receivedCount: captureB)

        let pipeline = PromptContextPipeline(providers: [pA, pB])
        _ = try await pipeline.assemble(messageCount: 42)

        XCTAssertEqual(captureA.value, 42)
        XCTAssertEqual(captureB.value, 42)
    }

    func test_messageCount_drivesAtDepthSortIndex() async throws {
        // `.atDepth(n)` sorts as `2 + (messageCount - n)`. For mc=10, n=1 sorts
        // higher than n=9 (closer to the latest turn). The sort must be re-run
        // against the messageCount the caller passes in, not a cached value.
        let provider = FakeProvider(slots: [
            slot(id: "deep", position: .atDepth(9)),
            slot(id: "shallow", position: .atDepth(1)),
        ])

        let pipeline = PromptContextPipeline(providers: [provider])
        let result = try await pipeline.assemble(messageCount: 10)

        // sortIndex with mc=10: deep -> 2 + (10-9) = 3; shallow -> 2 + (10-1) = 11.
        // So `deep` precedes `shallow`.
        XCTAssertEqual(result.map(\.id), ["deep", "shallow"])
    }
}

// `PromptSlot` is `Identifiable` but not `Equatable` in BCK today; tests above
// compare on `id` only, which is enough for the assertions made here.
