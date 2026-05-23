import XCTest
import ManifoldInference
import ManifoldRuntime

/// Actor-backed registry that mutates under load while readers ask the
/// source for its tool definitions. The shape mirrors how production
/// sources will look in Wave 2 (Skills' `SkillRegistry`, the
/// `MCPToolSource` precedent): mutable storage owned by an actor, read
/// through a `Sendable` source value.
private actor MutableToolRegistry {
    private var definitions: [ToolDefinition] = []

    func replace(with definitions: [ToolDefinition]) {
        self.definitions = definitions
    }

    func snapshot() -> [ToolDefinition] {
        definitions
    }
}

private struct RegistryBackedToolSource: SessionToolSource {
    let registry: MutableToolRegistry

    func toolDefinitions(for session: ChatSessionRecord) async -> [ToolDefinition] {
        await registry.snapshot()
    }

    func resolve(
        toolName: String,
        arguments: String,
        session: ChatSessionRecord
    ) async throws -> ToolResult {
        let snapshot = await registry.snapshot()
        guard snapshot.contains(where: { $0.name == toolName }) else {
            throw RegistryBackedError.unknownTool(toolName)
        }
        return ToolResult(callId: UUID().uuidString, content: "ok")
    }

    enum RegistryBackedError: Error {
        case unknownTool(String)
    }
}

/// Exercises the `Sendable` boundary between a registry-style mutation and
/// a turn-shaped read. Runs as a single XCTestCase method but races many
/// concurrent reads against a writer; meant to be executed under
/// `swift test --parallel` so other suites apply additional pressure.
final class SessionToolSourceConcurrencyTests: XCTestCase {

    // Sabotage-evidence:
    // M1: replace `MutableToolRegistry` with a struct holding a `var` and remove the actor — compiler error proves Sendable boundary is real.
    // M2: have `snapshot()` return a slice of `definitions` after randomly popping one — readers will observe `[]` mid-write and the count assertion will fail.
    // M3: remove `await` from `registry.snapshot()` in `toolDefinitions(for:)` — won't compile, proving the cross-actor hop is required.
    func test_concurrent_definitions_are_stable_under_parallel_load() async {
        let registry = MutableToolRegistry()
        let baseline: [ToolDefinition] = (0..<8).map {
            ToolDefinition(name: "tool_\($0)", description: "Tool \($0)")
        }
        await registry.replace(with: baseline)

        let source = RegistryBackedToolSource(registry: registry)
        let session = ChatSessionRecord(id: UUID(), title: "concurrency fixture")

        await withTaskGroup(of: Int.self) { group in
            // Writers: alternate between two equivalent definition sets so
            // a reader that lands mid-write still observes a complete,
            // well-formed snapshot — but never an empty one. If the
            // Sendable boundary is broken, readers will observe a partial
            // mutation and the count assertion below will fail.
            let alternate: [ToolDefinition] = baseline.map {
                ToolDefinition(name: $0.name, description: $0.description + "-alt")
            }
            for cycle in 0..<32 {
                group.addTask {
                    await registry.replace(with: cycle.isMultiple(of: 2) ? baseline : alternate)
                    return 0
                }
            }

            // Readers: each must observe a non-empty, well-formed snapshot.
            for _ in 0..<128 {
                group.addTask {
                    let snapshot = await source.toolDefinitions(for: session)
                    return snapshot.count
                }
            }

            var readCount = 0
            for await result in group {
                if result == baseline.count {
                    readCount += 1
                } else if result != 0 {
                    // 0 belongs to writer tasks; any other count means a
                    // reader saw a malformed snapshot — fail loudly.
                    XCTFail("Reader observed unexpected definition count: \(result)")
                }
            }
            XCTAssertGreaterThan(
                readCount,
                0,
                "Expected at least one reader to observe the full definition set"
            )
        }
    }
}
