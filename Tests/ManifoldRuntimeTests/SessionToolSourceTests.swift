import XCTest
import ManifoldInference
import ManifoldRuntime
import ManifoldContractTestSupport

/// Minimal in-test fixture used to exercise the ``SessionToolSource``
/// contract mixin. The shape mirrors how production sources (Skills,
/// HandoffToolSource) will be built in Wave 2: a snapshot of tool
/// definitions taken at init time, plus a dispatch closure.
private struct FixtureSessionToolSource: SessionToolSource {
    let definitions: [ToolDefinition]

    func toolDefinitions(for session: ChatSessionRecord) async -> [ToolDefinition] {
        definitions
    }

    func resolve(
        toolName: String,
        arguments: String,
        session: ChatSessionRecord
    ) async throws -> ToolResult {
        guard definitions.contains(where: { $0.name == toolName }) else {
            throw FixtureError.unknownTool(toolName)
        }
        return ToolResult(
            callId: UUID().uuidString,
            content: "ok"
        )
    }

    enum FixtureError: Error, Equatable {
        case unknownTool(String)
    }
}

final class SessionToolSourceTests: XCTestCase, SessionToolSourceContract {

    func makeSource() -> any SessionToolSource {
        FixtureSessionToolSource(definitions: [
            ToolDefinition(name: "echo", description: "Returns its input."),
            ToolDefinition(name: "ping", description: "Health check."),
        ])
    }

    // Sabotage-evidence:
    // M1: have toolDefinitions(for:) return a randomly shuffled copy on each call.
    // M2: have toolDefinitions(for:) return [] when called a second time.
    // M3: have toolDefinitions(for:) inject UUID() into the first tool's description on each call.
    func test_toolDefinitions_stableAcrossCalls() async {
        await assertSessionToolSource_toolDefinitions_stableAcrossCalls()
    }

    // Sabotage-evidence:
    // M1: remove the `guard definitions.contains` check and return a synthetic ToolResult.
    // M2: change `throw` to `return ToolResult(... output: "")` for unknown tools.
    // M3: have resolve fall through to a default success branch on any name.
    func test_resolve_unknownTool_throws() async {
        await assertSessionToolSource_resolve_unknownTool_throws()
    }

    // Sabotage-evidence:
    // M1: add `func allowedToolNames(for:) async -> Set<String>? { [] }` to FixtureSessionToolSource.
    // M2: override allowedToolNames to return Set(definitions.map(\.name)).
    // M3: remove the default-impl in SessionToolSource and require conformers to implement explicitly.
    func test_allowedToolNames_defaultsToNil() async {
        await assertSessionToolSource_allowedToolNames_defaultsToNil()
    }
}
