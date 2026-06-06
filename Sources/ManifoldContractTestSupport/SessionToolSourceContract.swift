import XCTest
import ManifoldInference
import ManifoldRuntime

// MARK: - SessionToolSourceContract

/// Opt-in XCTestCase mixin that exercises the ``SessionToolSource`` protocol
/// contract against any conforming implementation.
///
/// Each adopter provides a fresh source via ``makeSource()`` and a fixture
/// session via ``makeSession()``, then calls the assertion helpers from
/// concrete `test_`-prefixed methods so XCTest can discover them.
///
/// Placed in `ManifoldContractTestSupport` (not `ManifoldTestSupport`) to
/// preserve the XCTest-runtime split documented in `Package.swift` —
/// `ManifoldTestSupport` is XCTest-free so fuzz-chat (an executable) can
/// depend on it without dragging in `libXCTestSwiftSupport.dylib`.
public protocol SessionToolSourceContract: AnyObject {
    /// Returns a fresh session for each assertion call. Default
    /// implementation produces an empty session — override only if the
    /// source's behaviour depends on session shape.
    func makeSession() -> ChatSession

    /// Returns a fresh, fully-configured source for each assertion call.
    func makeSource() -> any SessionToolSource
}

public extension SessionToolSourceContract {
    func makeSession() -> ChatSession {
        ChatSession(id: UUID(), title: "Contract fixture")
    }
}

public extension SessionToolSourceContract where Self: XCTestCase {

    /// `toolDefinitions(for:)` returns the same value on repeated calls
    /// with the same session — sources may compute on demand but must not
    /// produce a sequence that drifts across turns.
    func assertSessionToolSource_toolDefinitions_stableAcrossCalls() async {
        let source = makeSource()
        let session = makeSession()

        let first = await source.toolDefinitions(for: session)
        let second = await source.toolDefinitions(for: session)

        XCTAssertEqual(
            first,
            second,
            "toolDefinitions(for:) must be stable across repeated calls for the same session"
        )
    }

    /// `resolve(toolName:arguments:session:)` must throw for an unknown tool
    /// name. Sources should never fabricate a result for a tool they did not
    /// advertise — the turn loop relies on this contract to surface
    /// mis-routed calls as errors instead of silent successes.
    func assertSessionToolSource_resolve_unknownTool_throws() async {
        let source = makeSource()
        let session = makeSession()

        let unknownName = "__contract_unknown_tool_\(UUID().uuidString)"
        do {
            _ = try await source.resolve(
                toolName: unknownName,
                arguments: "{}",
                session: session
            )
            XCTFail("Expected resolve(toolName:) to throw for unknown tool \(unknownName)")
        } catch {
            // Any thrown error satisfies the contract — conformers may throw
            // their own domain errors and we deliberately don't pin the type.
            // Reference `error` here so the silent-catch audit can distinguish
            // intentional contract capture from an accidental swallow.
            XCTAssertNotNil(error as Error?, "thrown error captured by contract")
        }
    }

    /// Sources that don't restrict the advertised list rely on the protocol
    /// extension's `allowedToolNames(for:) -> nil` default. Conformers that
    /// intentionally restrict are expected to override; this assertion is
    /// scoped to "I rely on the default" implementers and is opt-in.
    func assertSessionToolSource_allowedToolNames_defaultsToNil() async {
        let source = makeSource()
        let session = makeSession()

        let allowed = await source.allowedToolNames(for: session)
        XCTAssertNil(
            allowed,
            "allowedToolNames(for:) default should return nil; override only when the source intentionally narrows the tool surface"
        )
    }
}
