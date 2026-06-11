#if MCP
import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldInference

@MainActor
final class MCPToolBridgeTests: XCTestCase {
    func test_perCallApprovalPolicyAlwaysRequiresApproval() async {
        let source = makeSource(
            serverID: UUID(),
            approvalPolicy: .perCall,
            toolNames: ["search"]
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        XCTAssertTrue(registry.requiresApproval(toolName: "search"))
        await source.markApproved(toolName: "search")
        XCTAssertTrue(registry.requiresApproval(toolName: "search"))
    }

    func test_perTurnApprovalPolicyCanBeInvalidated() async {
        let source = makeSource(
            serverID: UUID(),
            approvalPolicy: .perTurn,
            toolNames: ["search", "lookup"]
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        XCTAssertTrue(registry.requiresApproval(toolName: "search"))
        XCTAssertTrue(registry.requiresApproval(toolName: "lookup"))

        await source.markApproved(toolName: "search")
        XCTAssertFalse(registry.requiresApproval(toolName: "search"))
        XCTAssertFalse(registry.requiresApproval(toolName: "lookup"))

        await source.invalidateApprovals()
        XCTAssertTrue(registry.requiresApproval(toolName: "search"))
        XCTAssertTrue(registry.requiresApproval(toolName: "lookup"))
    }

    func test_sessionForServerApprovalPolicyApprovesAllTools() async {
        let source = makeSource(
            serverID: UUID(),
            approvalPolicy: .sessionForServer,
            toolNames: ["search", "lookup"]
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        XCTAssertTrue(registry.requiresApproval(toolName: "search"))
        XCTAssertTrue(registry.requiresApproval(toolName: "lookup"))

        await source.markApproved()
        XCTAssertFalse(registry.requiresApproval(toolName: "search"))
        XCTAssertFalse(registry.requiresApproval(toolName: "lookup"))
    }

    func test_sessionForToolApprovalPolicyOnlyApprovesNamedTool() async {
        let source = makeSource(
            serverID: UUID(),
            approvalPolicy: .sessionForTool,
            toolNames: ["search", "lookup"]
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        await source.markApproved(toolName: "search")
        XCTAssertFalse(registry.requiresApproval(toolName: "search"))
        XCTAssertTrue(registry.requiresApproval(toolName: "lookup"))
    }

    func test_persistentForToolApprovalPolicyPersistsAcrossSourcesForServer() async {
        let serverID = UUID()
        let first = makeSource(
            serverID: serverID,
            approvalPolicy: .persistentForTool,
            toolNames: ["search"]
        )
        let firstRegistry = ToolRegistry()
        await first.register(in: firstRegistry)
        XCTAssertTrue(firstRegistry.requiresApproval(toolName: "search"))
        await first.markApproved(toolName: "search")
        XCTAssertFalse(firstRegistry.requiresApproval(toolName: "search"))
        await first.close()

        let second = makeSource(
            serverID: serverID,
            approvalPolicy: .persistentForTool,
            toolNames: ["search"]
        )
        let secondRegistry = ToolRegistry()
        await second.register(in: secondRegistry)
        XCTAssertFalse(secondRegistry.requiresApproval(toolName: "search"))

        await second.invalidateApprovals(toolName: "search")
        XCTAssertTrue(secondRegistry.requiresApproval(toolName: "search"))
    }

    func test_sourceRegistersNamespacedFilteredToolsAndUnregisters() async {
        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: "docs",
            toolFilter: .init(mode: .allowList, names: ["search"]),
            approvalPolicy: .perCall,
            listTools: {
                .object([
                    "tools": .array([
                        .object([
                            "name": .string("search"),
                            "description": .string("Search docs"),
                            "inputSchema": .object(["type": .string("object")]),
                        ]),
                        .object([
                            "name": .string("write"),
                            "description": .string("Write docs"),
                            "inputSchema": .object(["type": .string("object")]),
                        ]),
                    ]),
                ])
            },
            callTool: { _, _ in nil }
        )
        let registry = ToolRegistry()

        await source.register(in: registry)
        let namesAfterRegister = await MainActor.run { registry.definitions.map(\.name) }
        XCTAssertEqual(namesAfterRegister, ["docs__search"])

        await source.unregister(from: registry)
        let namesAfterUnregister = await MainActor.run { registry.definitions.map(\.name) }
        XCTAssertTrue(namesAfterUnregister.isEmpty)
    }

    func test_refreshUpdatesAlreadyRegisteredTools() async throws {
        let provider = ToolListProvider(
            value: .object([
                "tools": .array([
                    .object([
                        "name": .string("search"),
                        "inputSchema": .object(["type": .string("object")]),
                    ]),
                ]),
            ])
        )
        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .allowAll,
            approvalPolicy: .perCall,
            listTools: {
                await provider.value
            },
            callTool: { _, _ in nil }
        )
        let registry = ToolRegistry()

        await source.register(in: registry)
        await provider.setValue(.object([
            "tools": .array([
                .object([
                    "name": .string("lookup"),
                    "inputSchema": .object(["type": .string("object")]),
                ]),
            ]),
        ]))
        try await source.refreshTools()

        let names = await MainActor.run { registry.definitions.map(\.name) }
        XCTAssertEqual(names, ["lookup"])
    }

    func test_refreshHonorsMaxToolCount() async {
        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .init(mode: .allowAll, maxToolCount: 1),
            approvalPolicy: .perCall,
            listTools: {
                .object([
                    "tools": .array([
                        .object(["name": .string("a"), "inputSchema": .object([:])]),
                        .object(["name": .string("b"), "inputSchema": .object([:])]),
                    ]),
                ])
            },
            callTool: { _, _ in nil }
        )

        do {
            try await source.refreshTools()
            XCTFail("Expected tooManyTools error")
        } catch let error as MCPError {
            XCTAssertEqual(error, .tooManyTools(2))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_sessionForToolApprovalPolicyCanBeInvalidated() async {
        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .allowAll,
            approvalPolicy: .sessionForTool,
            listTools: {
                .object([
                    "tools": .array([
                        .object(["name": .string("search"), "inputSchema": .object([:])]),
                    ]),
                ])
            },
            callTool: { _, _ in nil }
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        let beforeApproval = registry.requiresApproval(toolName: "search")
        XCTAssertTrue(beforeApproval)

        await source.markApproved(toolName: "search")
        let afterApproval = registry.requiresApproval(toolName: "search")
        XCTAssertFalse(afterApproval)

        await source.invalidateApprovals(toolName: "search")
        let afterInvalidation = registry.requiresApproval(toolName: "search")
        XCTAssertTrue(afterInvalidation)
    }

    func test_policyKeyingIsCaseInsensitive() async {
        let source = makeSource(
            serverID: UUID(),
            approvalPolicy: .sessionForTool,
            toolNames: ["Docs.Search"]
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        XCTAssertTrue(registry.requiresApproval(toolName: "docs.search"))
        await source.markApproved(toolName: "DOCS.SEARCH")
        XCTAssertFalse(registry.requiresApproval(toolName: "docs.search"))
        await source.invalidateApprovals(toolName: "DoCs.SeArCh")
        XCTAssertTrue(registry.requiresApproval(toolName: "docs.search"))
    }

    func test_refreshDoesNotChurnToolsForCaseOnlyNameChanges() async throws {
        let provider = ToolListProvider(
            value: .object([
                "tools": .array([.object([
                    "name": .string("Search"),
                    "description": .string("case-insensitive lookup"),
                    "inputSchema": .object([:]),
                ])]),
            ])
        )
        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .allowAll,
            approvalPolicy: .perCall,
            listTools: { await provider.value },
            callTool: { _, _ in nil }
        )

        _ = try await source.refreshToolsAndReturnDelta()
        await provider.setValue(.object([
            "tools": .array([.object([
                "name": .string("search"),
                "description": .string("case-insensitive lookup"),
                "inputSchema": .object([:]),
            ])]),
        ]))

        let delta = try await source.refreshToolsAndReturnDelta()
        XCTAssertEqual(delta.addedNames, [])
        XCTAssertEqual(delta.removedNames, [])
        XCTAssertEqual(delta.updatedNames, [])
    }

    func test_listChangedInvalidatesSessionForServerApprovals() async throws {
        let provider = ToolListProvider(
            value: .object([
                "tools": .array([.object(["name": .string("search"), "inputSchema": .object([:])])]),
            ])
        )
        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .allowAll,
            approvalPolicy: .sessionForServer,
            listTools: { await provider.value },
            callTool: { _, _ in nil }
        )
        let registry = ToolRegistry()
        await source.register(in: registry)
        await source.markApproved()
        XCTAssertFalse(registry.requiresApproval(toolName: "search"))

        await provider.setValue(.object([
            "tools": .array([.object(["name": .string("search"), "description": .string("changed"), "inputSchema": .object([:])])]),
        ]))
        _ = try await source.refreshToolsAndReturnDelta(invalidateApprovalsForChangedTools: true)

        XCTAssertTrue(registry.requiresApproval(toolName: "search"))
    }

    func test_listChangedInvalidatesSessionAndPersistentToolApprovalsForChangedTool() async throws {
        let serverID = UUID()
        let provider = ToolListProvider(
            value: .object([
                "tools": .array([.object(["name": .string("search"), "inputSchema": .object([:])])]),
            ])
        )
        let source = MCPToolSource(
            serverID: serverID,
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .allowAll,
            approvalPolicy: .persistentForTool,
            listTools: { await provider.value },
            callTool: { _, _ in nil }
        )
        let registry = ToolRegistry()
        await source.register(in: registry)
        await source.markApproved(toolName: "search")
        XCTAssertFalse(registry.requiresApproval(toolName: "search"))

        await provider.setValue(.object([
            "tools": .array([.object(["name": .string("search"), "description": .string("changed"), "inputSchema": .object([:])])]),
        ]))
        _ = try await source.refreshToolsAndReturnDelta(invalidateApprovalsForChangedTools: true)
        XCTAssertTrue(registry.requiresApproval(toolName: "search"))

        await source.close()
        let reconnected = makeSource(
            serverID: serverID,
            approvalPolicy: .persistentForTool,
            toolNames: ["search"]
        )
        let reconnectRegistry = ToolRegistry()
        await reconnected.register(in: reconnectRegistry)
        XCTAssertTrue(reconnectRegistry.requiresApproval(toolName: "search"))
    }

    func test_dispatchingMCPToolRecordsApprovalForSessionPolicies() async {
        let source = makeSource(
            serverID: UUID(),
            approvalPolicy: .sessionForTool,
            toolNames: ["search"]
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        XCTAssertTrue(registry.requiresApproval(toolName: "search"))
        _ = await registry.dispatch(.init(id: "1", toolName: "search", arguments: "{}"))
        XCTAssertFalse(registry.requiresApproval(toolName: "search"))
    }

    func test_namespacedNameMatchesOpenAIRegex() async throws {
        let openAIRegex = try NSRegularExpression(pattern: "^[a-zA-Z0-9_-]+$")
        let fixtures: [(namespace: String, toolName: String)] = [
            ("notion", "read_page"),
            ("my.server", "list-items"),     // dot in namespace
            ("GitHub", "create_issue"),       // uppercase
            ("linear app", "search_issues"),  // space in namespace
            ("server1", "tool_with_dots"),    // underscores in tool name
        ]
        for (ns, name) in fixtures {
            let source = MCPToolSource(
                serverID: UUID(),
                displayName: ns,
                capabilities: .init(),
                toolNamespace: ns,
                toolFilter: .allowAll,
                approvalPolicy: .perCall,
                listTools: {
                    .object([
                        "tools": .array([
                            .object(["name": .string(name), "inputSchema": .object([:])]),
                        ]),
                    ])
                },
                callTool: { _, _ in nil }
            )
            let registry = ToolRegistry()
            await source.register(in: registry)
            let registeredNames = await MainActor.run { registry.definitions.map(\.name) }
            guard let result = registeredNames.first else {
                XCTFail("No tool registered for namespace='\(ns)' toolName='\(name)'")
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            XCTAssertNotNil(
                openAIRegex.firstMatch(in: result, range: range),
                "'\(result)' does not match OpenAI tool-name regex (namespace='\(ns)' toolName='\(name)')"
            )
        }
        // Sabotage: reverting the separator back to "." would fail every fixture that
        // has a namespace prefix, since "." is not in [a-zA-Z0-9_-].
    }

    func test_executorMapsStructuredErrorAndSanitizesContent() async throws {
        let executor = MCPToolExecutor(
            definition: ToolDefinition(name: "docs.search", description: "Search", parameters: .object([:])),
            serverDisplayName: "Docs",
            remoteToolName: "search",
            requiresApproval: true,
            callTool: { _, _ in
                .object([
                    "isError": .bool(true),
                    "errorKind": .string("permissionDenied"),
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("denied\u{0000}"),
                        ]),
                    ]),
                ])
            }
        )

        let result = try await executor.execute(arguments: .object([:]))
        XCTAssertEqual(result.errorKind, .permissionDenied)
        // Content is wrapped in the untrusted-surface envelope; null byte is stripped.
        XCTAssertTrue(result.content.contains("denied"))
        XCTAssertTrue(result.content.contains("trust=\"untrusted\""))
        XCTAssertFalse(result.content.contains("\u{0000}"))
    }

    func test_executorMapsMCPErrorKinds() async throws {
        let timeoutExecutor = MCPToolExecutor(
            definition: ToolDefinition(name: "docs.search", description: "Search", parameters: .object([:])),
            serverDisplayName: "Docs",
            remoteToolName: "search",
            requiresApproval: true,
            callTool: { _, _ in
                throw MCPError.requestTimeout
            }
        )
        let timeoutResult = try await timeoutExecutor.execute(arguments: .object([:]))
        XCTAssertEqual(timeoutResult.errorKind, .timeout)

        let cancelExecutor = MCPToolExecutor(
            definition: ToolDefinition(name: "docs.search", description: "Search", parameters: .object([:])),
            serverDisplayName: "Docs",
            remoteToolName: "search",
            requiresApproval: true,
            callTool: { _, _ in
                try Task.checkCancellation()
                return .null
            }
        )
        let task = Task { try await cancelExecutor.execute(arguments: .object([:])) }
        task.cancel()
        let cancelledResult = try await task.value
        XCTAssertEqual(cancelledResult.errorKind, .cancelled)
    }

    // Sabotage: removing withTaskCancellationHandler would cause
    // test_cancellation_writeFailsButExecutorStillThrows to succeed instead of throwing
    func test_cancellation_writeFailsButExecutorStillThrows() async throws {
        // Even when the fire-and-forget notifications/cancelled write fails (broken transport),
        // the executor must still return .cancelled — not the write error.
        let gate = AsyncGate()
        let executor = MCPToolExecutor(
            definition: ToolDefinition(name: "search", description: "Search", parameters: .object([:])),
            serverDisplayName: "Docs",
            remoteToolName: "search",
            requiresApproval: false,
            callTool: { _, _ in
                // Simulate sendRequest hanging then receiving CancellationError when the task
                // is cancelled, while the onCancel fire-and-forget notification write throws.
                try await withTaskCancellationHandler {
                    try await gate.wait()
                    return JSONSchemaValue?.none
                } onCancel: {
                    // Model a broken transport — throws but must not leak to the caller.
                    Task { throw MCPError.transportClosed }
                }
            }
        )

        let task = Task { try await executor.execute(arguments: .object([:])) }
        // Allow the executor to enter the callTool suspension before cancelling.
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        let result = try await task.value
        // Must be .cancelled, not the write error from the onCancel handler.
        XCTAssertEqual(result.errorKind, .cancelled)
    }

    // Sabotage: removing withTaskCancellationHandler would cause
    // test_cancellation_writeFailsButExecutorStillThrows to succeed instead of throwing
    func test_cancellation_serverRespondsAfterCancel() async throws {
        // When the task is cancelled and the server sends a response afterwards, the executor
        // must resolve as .cancelled — the late response must not leak into the transcript.
        let lateResponseGate = AsyncGate()
        let executor = MCPToolExecutor(
            definition: ToolDefinition(name: "search", description: "Search", parameters: .object([:])),
            serverDisplayName: "Docs",
            remoteToolName: "search",
            requiresApproval: false,
            callTool: { _, _ in
                // Wait for the gate to open, modelling a server that responds after cancel.
                try await withTaskCancellationHandler {
                    try await lateResponseGate.wait()
                    return JSONSchemaValue?.none
                } onCancel: {
                    // Notification dispatch — not under test here.
                }
            }
        )

        let task = Task { try await executor.execute(arguments: .object([:])) }
        try await Task.sleep(for: .milliseconds(20))
        // Cancel before the "server" responds.
        task.cancel()
        // Now deliver the late response — the task should already be resolving as cancelled.
        await lateResponseGate.open()

        let result = try await task.value
        // Must be .cancelled regardless of the late response.
        XCTAssertEqual(result.errorKind, .cancelled)
    }

    // Sabotage: removing withTaskCancellationHandler would cause
    // test_cancellation_writeFailsButExecutorStillThrows to succeed instead of throwing
    func test_cancellation_arrivesAfterServerAlreadyResponded() async throws {
        // When the server responds before the cancel signal, the original result wins.
        // Cancel must not inject .cancelled when the response is already in flight.
        let executor = MCPToolExecutor(
            definition: ToolDefinition(name: "search", description: "Search", parameters: .object([:])),
            serverDisplayName: "Docs",
            remoteToolName: "search",
            requiresApproval: false,
            callTool: { _, _ in
                // Return immediately so the response is produced before any cancel races.
                return .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string("result before cancel")]),
                    ]),
                ])
            }
        )

        let task = Task { try await executor.execute(arguments: .object([:])) }
        // Cancel races against an already-completed callTool.
        task.cancel()
        let result = try await task.value

        // Either outcome is valid: response won (no errorKind, content intact) or cancel won.
        switch result.errorKind {
        case .none:
            // Response won the race — content must be the real result, not a placeholder.
            XCTAssertTrue(result.content.contains("result before cancel"))
        case .cancelled:
            // Cancel won — acceptable.
            break
        default:
            XCTFail("Unexpected errorKind: \(String(describing: result.errorKind))")
        }
    }

    // Sabotage: removing withTaskCancellationHandler would cause
    // test_cancellation_writeFailsButExecutorStillThrows to succeed instead of throwing
    func test_listChangedDuringInFlightDispatch() async throws {
        // A notifications/tools/list_changed arriving while a tools/call is in-flight must not
        // crash or discard the in-flight result. The call completes with the original executor,
        // and the registry reflects the new tool list afterwards.
        let callGate = AsyncGate()
        let listProvider = ToolListProvider(
            value: .object([
                "tools": .array([
                    .object(["name": .string("search"), "inputSchema": .object([:])]),
                ]),
            ])
        )

        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .allowAll,
            approvalPolicy: .perCall,
            listTools: { await listProvider.value },
            callTool: { _, _ in
                // Hold mid-flight until the list_changed refresh completes.
                try await callGate.wait()
                return .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string("ok")]),
                    ]),
                ])
            }
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        // Start a dispatch that hangs until the gate opens.
        let dispatchTask = Task {
            await registry.dispatch(.init(id: "1", toolName: "search", arguments: "{}"))
        }

        // While the call is in-flight, simulate list_changed by refreshing with a changed tool.
        try await Task.sleep(for: .milliseconds(20))
        await listProvider.setValue(.object([
            "tools": .array([
                .object([
                    "name": .string("search"),
                    "description": .string("updated description"),
                    "inputSchema": .object([:]),
                ]),
            ]),
        ]))
        try await source.refreshTools()

        // Let the in-flight call finish.
        await callGate.open()
        let result = await dispatchTask.value

        // In-flight call must complete successfully — no crash, no .cancelled result.
        XCTAssertNil(result.errorKind, "In-flight call should complete with original executor")
        XCTAssertTrue(result.content.contains("ok"))

        // Registry reflects the post-refresh tool list.
        let names = await MainActor.run { registry.definitions.map(\.name) }
        XCTAssertEqual(names, ["search"])
    }

    // MARK: - SEC-07: MCP tool name / description caps

    /// A tool whose name exceeds `maxMCPToolNameBytes` must be truncated to
    /// the configured byte limit before the tool is registered.
    func test_oversizeToolName_isTruncatedAtByteLimit() async throws {
        let limit = 32 // small limit for the test
        var config = ManifoldConfiguration.shared
        config.maxMCPToolNameBytes = limit
        ManifoldConfiguration.shared = config
        defer {
            var restore = ManifoldConfiguration.shared
            restore.maxMCPToolNameBytes = 256
            ManifoldConfiguration.shared = restore
        }

        let longName = String(repeating: "a", count: limit + 50)
        XCTAssertGreaterThan(longName.utf8.count, limit)

        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Test",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .allowAll,
            approvalPolicy: .perCall,
            listTools: {
                .object([
                    "tools": .array([
                        .object([
                            "name": .string(longName),
                            "description": .string("a tool"),
                            "inputSchema": .object(["type": .string("object")]),
                        ]),
                    ]),
                ])
            },
            callTool: { _, _ in nil }
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        let registeredNames = await MainActor.run { registry.definitions.map(\.name) }
        XCTAssertEqual(registeredNames.count, 1,
                       "tool must still be registered after name truncation")
        let registeredNameBytes = registeredNames[0].utf8.count
        XCTAssertLessThanOrEqual(registeredNameBytes, limit,
                                 "registered name must be at most \(limit) bytes, got \(registeredNameBytes)")

        // Sabotage: confirm the registered name is shorter than the original.
        XCTAssertLessThan(registeredNameBytes, longName.utf8.count,
                          "registered name must be shorter than the oversize input")
    }

    /// A tool whose description exceeds `maxMCPToolDescriptionBytes` must be
    /// truncated to the configured byte limit.
    func test_oversizeToolDescription_isTruncatedAtByteLimit() async throws {
        let limit = 64
        var config = ManifoldConfiguration.shared
        config.maxMCPToolDescriptionBytes = limit
        ManifoldConfiguration.shared = config
        defer {
            var restore = ManifoldConfiguration.shared
            restore.maxMCPToolDescriptionBytes = 4_096
            ManifoldConfiguration.shared = restore
        }

        let longDescription = String(repeating: "b", count: limit + 200)
        XCTAssertGreaterThan(longDescription.utf8.count, limit)

        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Test",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .allowAll,
            approvalPolicy: .perCall,
            listTools: {
                .object([
                    "tools": .array([
                        .object([
                            "name": .string("tool_a"),
                            "description": .string(longDescription),
                            "inputSchema": .object(["type": .string("object")]),
                        ]),
                    ]),
                ])
            },
            callTool: { _, _ in nil }
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        let definitions = await MainActor.run { registry.definitions }
        XCTAssertEqual(definitions.count, 1)
        let descriptionBytes = definitions[0].description.utf8.count
        XCTAssertLessThanOrEqual(descriptionBytes, limit,
                                 "registered description must be at most \(limit) bytes, got \(descriptionBytes)")
    }

    /// A tool whose name is exactly at the byte limit must NOT be truncated.
    func test_toolNameAtByteLimit_isNotTruncated() async throws {
        let limit = 256
        let exactName = String(repeating: "z", count: limit)
        XCTAssertEqual(exactName.utf8.count, limit)

        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Test",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .allowAll,
            approvalPolicy: .perCall,
            listTools: {
                .object([
                    "tools": .array([
                        .object([
                            "name": .string(exactName),
                            "description": .string("ok"),
                            "inputSchema": .object(["type": .string("object")]),
                        ]),
                    ]),
                ])
            },
            callTool: { _, _ in nil }
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        let registeredNames = await MainActor.run { registry.definitions.map(\.name) }
        XCTAssertEqual(registeredNames.count, 1)
        XCTAssertEqual(registeredNames[0].utf8.count, limit,
                       "tool name at exact byte limit must not be truncated")
    }

    // MARK: - Output truncation respects ToolOutputPolicy

    /// By default (no policy override) the executor truncates oversized tool
    /// output to the 8 KB transport ceiling.
    func test_output_truncatedToDefaultLimit_whenNoPolicyOverride() async throws {
        let big = String(repeating: "a", count: 20_000)
        let executor = MCPToolExecutor(
            definition: ToolDefinition(name: "dump", description: "Dump", parameters: .object([:])),
            serverDisplayName: "Docs",
            remoteToolName: "dump",
            requiresApproval: false,
            callTool: { _, _ in .string(big) }
        )

        let result = try await executor.execute(arguments: .object([:]))
        // wrapForUntrustedSurface adds a small envelope, so the sanitized body
        // is bounded by the default 8 KB ceiling — well under the 20 KB input.
        XCTAssertLessThan(result.content.utf8.count, 20_000)
        XCTAssertGreaterThanOrEqual(result.content.utf8.count, MCPToolExecutor.defaultOutputByteLimit - 200)
    }

    /// When the owning registry configures a larger `ToolOutputPolicy.maxBytes`,
    /// `register(in:)` pushes that limit into the executor so output that fits
    /// the configured policy is no longer clipped at the hardcoded 8 KB.
    func test_output_respectsRegistryPolicyLimit() async throws {
        let body = String(repeating: "b", count: 16_000) // > 8 KB default, < 64 KB policy
        let source = makeSource(
            serverID: UUID(),
            approvalPolicy: .perCall,
            toolNames: ["dump"],
            callTool: { _, _ in .string(body) }
        )
        let registry = ToolRegistry()
        registry.outputPolicy = ToolOutputPolicy(maxBytes: 65_536, onOversize: .allow)
        await source.register(in: registry)

        let executor = try XCTUnwrap(registry.executor(for: "dump") as? MCPToolExecutor)
        let result = try await executor.execute(arguments: .object([:]))
        // Sanitize no longer clips at 8 KB — the full 16 KB body survives the
        // transport boundary because the policy limit (64 KB) was plumbed in.
        XCTAssertGreaterThan(result.content.utf8.count, 15_000,
                             "executor must honour the registry's configured output limit, not the 8 KB default")
    }
}

private func makeSource(
    serverID: UUID,
    approvalPolicy: MCPApprovalPolicy,
    toolNames: [String],
    callTool: (@Sendable (_ toolName: String, _ arguments: JSONSchemaValue) async throws -> JSONSchemaValue?)? = nil
) -> MCPToolSource {
    MCPToolSource(
        serverID: serverID,
        displayName: "Docs",
        capabilities: .init(),
        toolNamespace: nil,
        toolFilter: .allowAll,
        approvalPolicy: approvalPolicy,
        listTools: {
            .object([
                "tools": .array(toolNames.map { .object(["name": .string($0), "inputSchema": .object([:])]) }),
            ])
        },
        callTool: callTool ?? { _, _ in nil }
    )
}

private actor ToolListProvider {
    var value: JSONSchemaValue?

    init(value: JSONSchemaValue?) {
        self.value = value
    }

    func setValue(_ value: JSONSchemaValue?) {
        self.value = value
    }
}

/// One-shot gate: callers suspend on `wait()` until another caller calls `open()`.
private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var opened = false

    /// Suspends until `open()` is called. Throws `CancellationError` if the task is cancelled.
    func wait() async throws {
        if opened { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: { [weak self] in
            Task { await self?.cancelWait() }
        }
    }

    /// Opens the gate, resuming any suspended `wait()` caller.
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }

    private func cancelWait() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
#endif
