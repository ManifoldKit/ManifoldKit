import Foundation
import ManifoldInference

public final class MCPToolSource: @unchecked Sendable {
    public let serverID: UUID
    public let displayName: String
    private let capabilitiesValue: MCPCapabilities
    private let toolNamespace: String?
    private let toolFilter: MCPToolFilter
    private let listTools: (@Sendable () async throws -> JSONSchemaValue?)?
    private let callTool: (@Sendable (_ toolName: String, _ arguments: JSONSchemaValue) async throws -> JSONSchemaValue?)?
    private let storage: MCPToolSourceStorage
    @MainActor private var registeredRegistries: [ObjectIdentifier: ToolRegistry] = [:]
    @MainActor private var registeredNamesByRegistry: [ObjectIdentifier: Set<String>] = [:]

    public init(
        serverID: UUID,
        displayName: String,
        capabilities: MCPCapabilities = .init()
    ) {
        self.serverID = serverID
        self.displayName = displayName
        self.capabilitiesValue = capabilities
        self.toolNamespace = nil
        self.toolFilter = .allowAll
        self.listTools = nil
        self.callTool = nil
        self.storage = MCPToolSourceStorage(serverID: serverID, serverDisplayName: displayName, approvalPolicy: .perCall)
    }

    internal init(
        serverID: UUID,
        displayName: String,
        capabilities: MCPCapabilities,
        toolNamespace: String?,
        toolFilter: MCPToolFilter,
        approvalPolicy: MCPApprovalPolicy,
        listTools: (@Sendable () async throws -> JSONSchemaValue?)?,
        callTool: (@Sendable (_ toolName: String, _ arguments: JSONSchemaValue) async throws -> JSONSchemaValue?)?
    ) {
        self.serverID = serverID
        self.displayName = displayName
        self.capabilitiesValue = capabilities
        self.toolNamespace = toolNamespace
        self.toolFilter = toolFilter
        self.listTools = listTools
        self.callTool = callTool
        self.storage = MCPToolSourceStorage(serverID: serverID, serverDisplayName: displayName, approvalPolicy: approvalPolicy)
    }

    public var capabilities: MCPCapabilities {
        get async { capabilitiesValue }
    }

    public func currentToolNames() async -> [String] {
        await storage.currentToolNames()
    }

    /// Returns the currently-registered tools whose JSON Schemas are compatible
    /// with Apple's Foundation Models tool surface.
    ///
    /// Foundation Models rejects schemas that use composition keywords
    /// (`oneOf`, `anyOf`, `allOf`), `$ref`, nullable type unions, or whose
    /// nesting exceeds a small depth. This query returns the namespaced names
    /// of tools whose schemas pass those conservative checks, sorted alphabetically.
    ///
    /// "Deep nesting" is defined as the maximum depth of nested `object`
    /// (`properties`) or `array` (`items`) descents within the schema.
    /// `maxDepth: 4` accepts e.g. `{type:object, properties:{x:{type:array,
    /// items:{type:object, properties:{y:{type:string}}}}}}` (depth 3) but
    /// rejects schemas that nest one level deeper. Depth is measured from the
    /// root schema (depth 1 = the root object), so a flat
    /// `{type:object, properties:{x:{type:string}}}` is depth 2.
    ///
    /// - Parameter maxDepth: Maximum allowed schema nesting depth. Defaults to
    ///   4, which empirically covers most well-formed MCP server tools while
    ///   rejecting recursive or deeply-nested OpenAPI-style schemas that
    ///   Foundation Models can't handle.
    public func foundationModelsCompatibleNames(maxDepth: Int = 4) async -> [String] {
        let tools = await storage.currentTools()
        return tools
            .filter { isFoundationModelsCompatible($0.inputSchema, maxDepth: maxDepth) }
            .map(\.namespacedName)
            .sorted()
    }

    /// Alias for ``foundationModelsCompatibleNames(maxDepth:)`` using the
    /// issue-tracker wording: names compatible under `maxDepth`.
    public func foundationModelsCompatibleNames(under maxDepth: Int) async -> [String] {
        await foundationModelsCompatibleNames(maxDepth: maxDepth)
    }

    /// Returns the subset of currently-registered tools that should be exposed
    /// to Apple's Foundation Models backend in a given turn.
    ///
    /// Composes ``foundationModelsCompatibleNames(maxDepth:)`` with a hard cap
    /// (defaulting to ``MCPToolFilter/foundationModelsToolCap``). When more
    /// compatible tools exist than the cap allows, the lexicographically-first
    /// `cap` names are returned — deterministic ordering keeps the UI's
    /// "X of Y enabled" count stable across refreshes.
    ///
    /// - Parameters:
    ///   - maxDepth: Forwarded to the schema-compatibility check.
    ///   - cap: Maximum number of tools to return. Defaults to 16.
    public func foundationModelsEnabledNames(
        maxDepth: Int = 4,
        cap: Int = MCPToolFilter.foundationModelsToolCap
    ) async -> [String] {
        let compatible = await foundationModelsCompatibleNames(maxDepth: maxDepth)
        guard cap >= 0 else { return [] }
        return Array(compatible.prefix(cap))
    }

    @MainActor public func register(in registry: ToolRegistry) async {
        if await storage.isEmpty(), listTools != nil {
            do {
                try await refreshTools()
            } catch {
                Log.inference.warning("MCPToolSource: failed to refresh tools for '\(self.displayName, privacy: .public)' during registration: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        let executors = await storage.executors()
        // Push the registry's configured output-size policy into each executor
        // so the transport-boundary truncation respects ToolOutputPolicy instead
        // of a hardcoded 8 KB constant. The registry applies its own oversize
        // action afterwards; this just stops us silently discarding the tail at
        // a lower fixed ceiling first.
        let outputLimit = registry.outputPolicy.maxBytes
        for executor in executors {
            executor.setOutputByteLimit(outputLimit)
            registry.register(executor)
        }
        let key = ObjectIdentifier(registry)
        registeredRegistries[key] = registry
        registeredNamesByRegistry[key] = Set(executors.map(\.definition.name))
    }

    @MainActor public func unregister(from registry: ToolRegistry) async {
        let key = ObjectIdentifier(registry)
        let names: Set<String>
        if let existing = registeredNamesByRegistry.removeValue(forKey: key) {
            names = existing
        } else {
            names = Set(await storage.currentToolNames())
        }
        for name in names {
            registry.unregister(name: name)
        }
        registeredRegistries.removeValue(forKey: key)
    }

    public func refreshTools() async throws {
        _ = try await refreshToolsAndReturnDelta()
    }

    public func markApproved(toolName: String? = nil) async {
        await storage.markApproved(toolName: toolName)
    }

    public func invalidateApprovals(toolName: String? = nil) async {
        await storage.invalidateApprovals(toolName: toolName)
    }

    @MainActor public func close() async {
        for (key, registry) in registeredRegistries {
            let names = registeredNamesByRegistry[key] ?? []
            for name in names {
                registry.unregister(name: name)
            }
        }
        registeredRegistries.removeAll()
        registeredNamesByRegistry.removeAll()
        await storage.removeAll()
    }

    internal func refreshToolsAndReturnDelta(
        invalidateApprovalsForChangedTools: Bool = false
    ) async throws -> MCPToolRefreshDelta {
        guard let listTools else { return .empty }
        let response = try await listTools()
        let parsed = try Self.parseToolsListResponse(response)
        let filtered = try applyFilterAndNamespace(tools: parsed)
        let delta = await storage.replaceTools(
            with: filtered,
            invalidateApprovalsForChangedTools: invalidateApprovalsForChangedTools,
            callTool: callTool
        )
        await updateRegisteredRegistries(delta: delta)
        return delta
    }

    private func applyFilterAndNamespace(tools: [MCPRemoteTool]) throws -> [MCPRemoteTool] {
        let filtered = tools.filter { toolFilter.includes(name: $0.originalName) }
        if filtered.count > toolFilter.maxToolCount {
            throw MCPError.tooManyTools(filtered.count)
        }

        let namespacePrefix = normalizedNamespace(toolNamespace)
        var seen: Set<String> = []
        return try filtered.map { tool in
            let namespacedName = namespacePrefix.map { "\($0)__\(tool.originalName)" } ?? tool.originalName
            let key = namespacedName.lowercased()
            if seen.contains(key) {
                throw MCPError.malformedMetadata("Duplicate tool name after namespacing: \(namespacedName)")
            }
            seen.insert(key)
            return MCPRemoteTool(
                originalName: tool.originalName,
                namespacedName: namespacedName,
                description: tool.description,
                inputSchema: tool.inputSchema
            )
        }
    }

    private func updateRegisteredRegistries(delta: MCPToolRefreshDelta) async {
        guard !(delta.upsertExecutors.isEmpty && delta.removedNames.isEmpty) else { return }

        await MainActor.run {
            for (key, registry) in registeredRegistries {
                for removedName in delta.removedNames {
                    registry.unregister(name: removedName)
                }
                for executor in delta.upsertExecutors {
                    registry.register(executor)
                }
                registeredNamesByRegistry[key] = Set(delta.allNames)
            }
        }
    }

    private static func parseToolsListResponse(_ response: JSONSchemaValue?) throws -> [MCPRemoteTool] {
        guard case .object(let root)? = response else {
            throw MCPError.malformedMetadata("tools/list response must be an object")
        }
        guard case .array(let toolValues)? = root["tools"] else {
            throw MCPError.malformedMetadata("tools/list response missing tools array")
        }
        let config = ManifoldConfiguration.shared
        return try toolValues.map { value in
            guard case .object(let object) = value else {
                throw MCPError.malformedMetadata("tools/list item must be an object")
            }
            guard case .string(let rawName)? = object["name"], !rawName.isEmpty else {
                throw MCPError.malformedMetadata("tools/list item missing name")
            }
            // Cap name and description by UTF-8 byte count before construction
            // so an adversarial MCP server can't inject unbounded metadata into
            // the tool registry. Log a warning so operators can detect it.
            // The fallback on failed UTF-8 decode is String.Substring prefix by
            // character (grapheme cluster) rather than the raw input — this closes
            // the inconsistency where a multi-byte grapheme straddles the byte cap
            // and the fallback silently accepts the full, uncapped string.
            let name: String
            if rawName.utf8.count > config.maxMCPToolNameBytes {
                let truncated = String(
                    bytes: Array(rawName.utf8.prefix(config.maxMCPToolNameBytes)),
                    encoding: .utf8
                ) ?? String(rawName.prefix(config.maxMCPToolNameBytes))
                name = truncated
                Log.inference.warning("MCPToolSource: tool name truncated from \(rawName.utf8.count) to \(config.maxMCPToolNameBytes) bytes")
            } else {
                name = rawName
            }
            MCPContentSanitizer.logInjectionIndicators(in: name, field: "tool name", toolName: name)
            let description: String
            if case .string(let rawDescription)? = object["description"] {
                if rawDescription.utf8.count > config.maxMCPToolDescriptionBytes {
                    let truncated = String(
                        bytes: Array(rawDescription.utf8.prefix(config.maxMCPToolDescriptionBytes)),
                        encoding: .utf8
                    ) ?? String(rawDescription.prefix(config.maxMCPToolDescriptionBytes))
                    Log.inference.warning("MCPToolSource: tool description truncated from \(rawDescription.utf8.count) to \(config.maxMCPToolDescriptionBytes) bytes for tool '\(name, privacy: .public)'")
                    description = truncated
                } else {
                    description = rawDescription
                }
                MCPContentSanitizer.logInjectionIndicators(in: description, field: "tool description", toolName: name)
            } else {
                description = "MCP tool '\(name)'"
            }
            let schema: JSONSchemaValue
            if let inputSchema = object["inputSchema"] {
                schema = inputSchema
            } else if let parameters = object["parameters"] {
                schema = parameters
            } else {
                schema = .object([:])
            }
            // Scan parameter descriptions — they appear verbatim in the model's
            // context window alongside parameter names and are an equally viable
            // injection vector as the top-level tool description.
            MCPContentSanitizer.logInjectionIndicatorsInSchema(schema, toolName: name)
            return MCPRemoteTool(
                originalName: name,
                namespacedName: name,
                description: description,
                inputSchema: schema
            )
        }
    }
}

// MARK: - Internal model shared between MCPToolSource and MCPToolSourceStorage

struct MCPRemoteTool: Sendable, Equatable {
    let originalName: String
    let namespacedName: String
    let description: String
    let inputSchema: JSONSchemaValue
}

internal struct MCPToolRefreshDelta: Sendable {
    let addedNames: [String]
    let removedNames: [String]
    let updatedNames: [String]
    let allNames: [String]
    let upsertExecutors: [MCPToolExecutor]

    static let empty = MCPToolRefreshDelta(
        addedNames: [],
        removedNames: [],
        updatedNames: [],
        allNames: [],
        upsertExecutors: []
    )
}

// MARK: - Storage actor for MCPToolSource

private actor MCPToolSourceStorage {
    private let serverID: UUID
    private let serverDisplayName: String
    private let approvalPolicy: MCPApprovalPolicy
    private var executorsByStableKey: [String: MCPToolExecutor] = [:]
    private var toolsByStableKey: [String: MCPRemoteTool] = [:]
    private var approvedToolNames: Set<String> = []
    private var serverApproved = false
    private var turnApproved = false

    init(serverID: UUID, serverDisplayName: String, approvalPolicy: MCPApprovalPolicy) {
        self.serverID = serverID
        self.serverDisplayName = serverDisplayName
        self.approvalPolicy = approvalPolicy
    }

    func isEmpty() -> Bool {
        executorsByStableKey.isEmpty
    }

    func executors() -> [MCPToolExecutor] {
        executorsByStableKey.values.sorted { $0.definition.name < $1.definition.name }
    }

    func currentToolNames() -> [String] {
        executorsByStableKey.values.map(\.definition.name).sorted()
    }

    func currentTools() -> [MCPRemoteTool] {
        Array(toolsByStableKey.values)
    }

    func replaceTools(
        with tools: [MCPRemoteTool],
        invalidateApprovalsForChangedTools: Bool,
        callTool: (@Sendable (_ toolName: String, _ arguments: JSONSchemaValue) async throws -> JSONSchemaValue?)?
    ) async -> MCPToolRefreshDelta {
        if approvalPolicy == .persistentForTool {
            // Reload persisted approvals from UserDefaults at each replaceTools call
            // so a newly-created storage actor picks up approvals from prior app
            // sessions. We check every incoming tool so freshly-reconnected servers
            // inherit durable approvals without requiring a re-prompt.
            let store = MCPPersistentToolApprovalStore.shared
            for tool in tools {
                let stableKey = stableToolKey(for: tool.namespacedName)
                if store.isApproved(serverID: serverID, toolName: stableKey) {
                    approvedToolNames.insert(stableKey)
                }
            }
        }

        let previousExecutors = executorsByStableKey
        let previousTools = toolsByStableKey
        let previousKeys = Set(previousExecutors.keys)

        var nextExecutors: [String: MCPToolExecutor] = [:]
        var nextTools: [String: MCPRemoteTool] = [:]
        var updatedKeys: Set<String> = []

        for tool in tools {
            let stableKey = stableToolKey(for: tool.namespacedName)
            if let previousTool = previousTools[stableKey],
               previousTool.isSemanticallyEquivalent(to: tool),
               let previousExecutor = previousExecutors[stableKey] {
                nextExecutors[stableKey] = previousExecutor
                nextTools[stableKey] = previousTool
                continue
            }

            if previousTools[stableKey] != nil {
                updatedKeys.insert(stableKey)
            }

            let requiresApproval = approvalRequired(for: stableKey)
            let executor = MCPToolExecutor(
                definition: ToolDefinition(
                    name: tool.namespacedName,
                    description: tool.description,
                    parameters: tool.inputSchema
                ),
                serverDisplayName: serverDisplayName,
                remoteToolName: tool.originalName,
                requiresApproval: requiresApproval,
                toolApprovalDidSucceed: { [weak self] in
                    await self?.markApproved(toolName: tool.namespacedName)
                },
                callTool: callTool ?? { name, _ in
                    throw MCPError.toolNotFound(name)
                }
            )
            nextExecutors[stableKey] = executor
            nextTools[stableKey] = tool
        }

        let nextKeys = Set(nextExecutors.keys)
        let addedKeys = nextKeys.subtracting(previousKeys)
        let removedKeys = previousKeys.subtracting(nextKeys)
        let changedKeys = addedKeys.union(removedKeys).union(updatedKeys)

        approvedToolNames = approvedToolNames.filter { nextKeys.contains($0) }

        if invalidateApprovalsForChangedTools, changedKeys.isEmpty == false {
            switch approvalPolicy {
            case .perCall:
                break
            case .perTurn:
                turnApproved = false
            case .sessionForServer:
                serverApproved = false
            case .sessionForTool:
                approvedToolNames.subtract(updatedKeys)
                approvedToolNames.subtract(removedKeys)
            case .persistentForTool:
                approvedToolNames.subtract(updatedKeys)
                approvedToolNames.subtract(removedKeys)
                let store = MCPPersistentToolApprovalStore.shared
                for toolName in updatedKeys.union(removedKeys) {
                    store.revoke(serverID: serverID, toolName: toolName)
                }
            }
        }

        executorsByStableKey = nextExecutors
        toolsByStableKey = nextTools
        applyApprovalPolicy()

        let addedNames = addedKeys.compactMap { nextExecutors[$0]?.definition.name }.sorted()
        let removedNames = removedKeys.compactMap { previousExecutors[$0]?.definition.name }.sorted()
        let updatedNames = updatedKeys.compactMap { nextExecutors[$0]?.definition.name }.sorted()
        let allNames = nextExecutors.values.map(\.definition.name).sorted()
        let upsertKeys = addedKeys.union(updatedKeys)
        let upsertExecutors = upsertKeys.compactMap { nextExecutors[$0] }
            .sorted { $0.definition.name < $1.definition.name }

        return MCPToolRefreshDelta(
            addedNames: addedNames,
            removedNames: removedNames,
            updatedNames: updatedNames,
            allNames: allNames,
            upsertExecutors: upsertExecutors
        )
    }

    func markApproved(toolName: String?) async {
        switch approvalPolicy {
        case .perCall:
            return
        case .perTurn:
            turnApproved = true
        case .sessionForServer:
            serverApproved = true
        case .sessionForTool, .persistentForTool:
            if let toolName {
                let stableName = stableToolKey(for: toolName)
                approvedToolNames.insert(stableName)
                if approvalPolicy == .persistentForTool {
                    MCPPersistentToolApprovalStore.shared.approve(serverID: serverID, toolName: stableName)
                }
            }
        }
        applyApprovalPolicy()
    }

    func invalidateApprovals(toolName: String?) async {
        switch approvalPolicy {
        case .perCall:
            return
        case .perTurn:
            turnApproved = false
        case .sessionForServer:
            serverApproved = false
        case .sessionForTool, .persistentForTool:
            if let toolName {
                let stableName = stableToolKey(for: toolName)
                approvedToolNames.remove(stableName)
                if approvalPolicy == .persistentForTool {
                    MCPPersistentToolApprovalStore.shared.revoke(serverID: serverID, toolName: stableName)
                }
            } else {
                approvedToolNames.removeAll()
                if approvalPolicy == .persistentForTool {
                    MCPPersistentToolApprovalStore.shared.revokeAll(serverID: serverID)
                }
            }
        }
        applyApprovalPolicy()
    }

    func removeAll() {
        executorsByStableKey.removeAll()
        toolsByStableKey.removeAll()
        approvedToolNames.removeAll()
        serverApproved = false
        turnApproved = false
    }

    private func applyApprovalPolicy() {
        for (stableKey, executor) in executorsByStableKey {
            executor.setRequiresApproval(approvalRequired(for: stableKey))
        }
    }

    private func approvalRequired(for stableToolName: String) -> Bool {
        switch approvalPolicy {
        case .perCall:
            return true
        case .perTurn:
            return turnApproved == false
        case .sessionForTool, .persistentForTool:
            return approvedToolNames.contains(stableToolName) == false
        case .sessionForServer:
            return serverApproved == false
        }
    }
}

// Internal so tests can instantiate directly with an isolated UserDefaults suite.
//
// Not an actor: UserDefaults is internally thread-safe (CFPreferences-backed), so
// there is no shared mutable state here that requires actor isolation. Making this
// a struct with @unchecked Sendable lets callers construct instances without
// crossing Swift 6 region-isolation boundaries — which actor inits would require
// for a non-Sendable UserDefaults argument.
internal struct MCPPersistentToolApprovalStore: @unchecked Sendable {
    static let shared = MCPPersistentToolApprovalStore(defaults: .standard)

    private let defaults: UserDefaults
    private static let keyPrefix = "com.manifoldkit.mcp.tool.approval."

    // No default value for `defaults` — call site must supply explicitly.
    // Do NOT add `= .standard` here; injected UserDefaults required for
    // parallel-test isolation per CLAUDE.md convention (cf. #734, #761).
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func isApproved(serverID: UUID, toolName: String) -> Bool {
        defaults.bool(forKey: key(serverID, toolName))
    }

    func approve(serverID: UUID, toolName: String) {
        defaults.set(true, forKey: key(serverID, toolName))
    }

    func revoke(serverID: UUID, toolName: String) {
        defaults.removeObject(forKey: key(serverID, toolName))
    }

    func revokeAll(serverID: UUID) {
        let prefix = "\(Self.keyPrefix)\(serverID.uuidString.lowercased())."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func key(_ serverID: UUID, _ toolName: String) -> String {
        "\(Self.keyPrefix)\(serverID.uuidString.lowercased()).\(toolName)"
    }
}

private func stableToolKey(for toolName: String) -> String {
    toolName.lowercased()
}

private extension MCPRemoteTool {
    func isSemanticallyEquivalent(to other: MCPRemoteTool) -> Bool {
        namespacedName.compare(other.namespacedName, options: .caseInsensitive) == .orderedSame &&
            originalName.compare(other.originalName, options: .caseInsensitive) == .orderedSame &&
            description == other.description &&
            inputSchema == other.inputSchema
    }
}

private func normalizedNamespace(_ namespace: String?) -> String? {
    guard let namespace else { return nil }
    let trimmed = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    // Dots and whitespace are invalid in OpenAI tool names — replace with underscores.
    let normalized = trimmed
        .replacingOccurrences(of: ".", with: "_")
        .components(separatedBy: .whitespaces)
        .filter { !$0.isEmpty }
        .joined(separator: "_")
    return normalized.isEmpty ? nil : normalized
}

// MARK: - Foundation Models schema compatibility

/// Returns `true` when `schema` avoids Foundation Models-incompatible JSON
/// Schema constructs and no nested `object`/`array` chain is deeper than
/// `maxDepth` levels.
///
/// Internal so tests in the same module can exercise edge cases directly.
internal func isFoundationModelsCompatible(_ schema: JSONSchemaValue, maxDepth: Int) -> Bool {
    schemaDepthIfCompatible(schema, currentDepth: 1, maxDepth: maxDepth) != nil
}

/// Recursive walker. Returns `nil` the moment an unsupported construct is
/// found (rejecting the whole schema); otherwise returns the maximum depth
/// reached. The depth is "interesting" only as a guard against the recursive
/// case — callers just look at `nil` vs `non-nil`.
///
/// **Strategy** (PR #797 review fix): the walker visits *every* JSON Schema
/// keyword that can carry a subschema, not just `properties`/`items`, so the
/// rejection rules (`oneOf`, `anyOf`, `allOf`, `$ref`, and type unions) are
/// evaluated at every nesting level the author can construct — including those
/// hidden inside `not`, `additionalProperties`, or `$defs`.
///
/// Two flavours of recursion:
/// - **Depth-advancing** edges (`properties`, `items`, `prefixItems`,
///   `additionalProperties`, `patternProperties`, `unevaluatedProperties`,
///   `unevaluatedItems`, `contains`, `propertyNames`): each edge counts as one
///   level of user-facing object/array nesting and contributes to `maxDepth`.
/// - **Transparent** composition edges (`not`, `if`/`then`/`else`, `$defs`,
///   `definitions`, `dependentSchemas`): these compose constraints over the
///   *current* node, so they don't add user-facing depth — but we still recurse
///   so a nested unsupported keyword can't smuggle past the filter.
private func schemaDepthIfCompatible(
    _ schema: JSONSchemaValue,
    currentDepth: Int,
    maxDepth: Int
) -> Int? {
    if currentDepth > maxDepth { return nil }

    switch schema {
    case .object(let object):
        // Reject the constructs Foundation Models can't decode at any level.
        if object["oneOf"] != nil { return nil }
        if object["$ref"] != nil { return nil }
        // anyOf is also not in Apple's accepted vocabulary; reject it for symmetry
        // since it's structurally the same hazard as oneOf.
        if object["anyOf"] != nil { return nil }
        if object["allOf"] != nil { return nil }
        // JSON Schema encodes nullable unions as `type: ["string", "null"]`.
        // Foundation Models expects a single concrete type, so reject any union.
        if case .array? = object["type"] { return nil }

        var deepest = currentDepth

        // --- Depth-advancing edges ----------------------------------------
        // `properties: { name: schema, ... }` — each property is one level deeper.
        if case .object(let properties)? = object["properties"] {
            for (_, child) in properties {
                guard let d = schemaDepthIfCompatible(child, currentDepth: currentDepth + 1, maxDepth: maxDepth)
                else { return nil }
                deepest = max(deepest, d)
            }
        }
        // `patternProperties: { regex: schema }` — same shape as properties.
        if case .object(let patterns)? = object["patternProperties"] {
            for (_, child) in patterns {
                guard let d = schemaDepthIfCompatible(child, currentDepth: currentDepth + 1, maxDepth: maxDepth)
                else { return nil }
                deepest = max(deepest, d)
            }
        }
        // `additionalProperties` / `unevaluatedProperties`: bool form is a
        // permissive flag (nothing to inspect); schema (object) form is a single
        // nested schema, one level deeper.
        for key in ["additionalProperties", "unevaluatedProperties"] {
            if let value = object[key], case .object = value {
                guard let d = schemaDepthIfCompatible(value, currentDepth: currentDepth + 1, maxDepth: maxDepth)
                else { return nil }
                deepest = max(deepest, d)
            }
        }
        // `items` may be a single schema or an array of schemas (legacy tuple form).
        if let items = object["items"] {
            if case .array(let tuple) = items {
                for child in tuple {
                    guard let d = schemaDepthIfCompatible(child, currentDepth: currentDepth + 1, maxDepth: maxDepth)
                    else { return nil }
                    deepest = max(deepest, d)
                }
            } else if case .object = items {
                guard let d = schemaDepthIfCompatible(items, currentDepth: currentDepth + 1, maxDepth: maxDepth)
                else { return nil }
                deepest = max(deepest, d)
            }
        }
        // `prefixItems: [schema, ...]` — modern tuple form.
        if case .array(let prefix)? = object["prefixItems"] {
            for child in prefix {
                guard let d = schemaDepthIfCompatible(child, currentDepth: currentDepth + 1, maxDepth: maxDepth)
                else { return nil }
                deepest = max(deepest, d)
            }
        }
        // `contains` / `unevaluatedItems` / `propertyNames`: single nested schema, one level deeper.
        for key in ["contains", "unevaluatedItems", "propertyNames"] {
            if let value = object[key], case .object = value {
                guard let d = schemaDepthIfCompatible(value, currentDepth: currentDepth + 1, maxDepth: maxDepth)
                else { return nil }
                deepest = max(deepest, d)
            }
        }

        // --- Transparent composition edges --------------------------------
        // `not: schema`, `if`/`then`/`else: schema` — single composition schemas.
        for key in ["not", "if", "then", "else"] {
            if let value = object[key], case .object = value {
                guard let d = schemaDepthIfCompatible(value, currentDepth: currentDepth, maxDepth: maxDepth)
                else { return nil }
                deepest = max(deepest, d)
            }
        }
        // `$defs` / `definitions` / `dependentSchemas: { name: schema }` — named maps, no depth bump.
        for key in ["$defs", "definitions", "dependentSchemas"] {
            if case .object(let defs)? = object[key] {
                for (_, child) in defs {
                    guard let d = schemaDepthIfCompatible(child, currentDepth: currentDepth, maxDepth: maxDepth)
                    else { return nil }
                    deepest = max(deepest, d)
                }
            }
        }

        return deepest
    case .array(let elements):
        // A bare schema array — descend without advancing depth (the array
        // container was already counted at the parent edge).
        var deepest = currentDepth
        for element in elements {
            guard let d = schemaDepthIfCompatible(element, currentDepth: currentDepth, maxDepth: maxDepth)
            else { return nil }
            deepest = max(deepest, d)
        }
        return deepest
    case .string, .integer, .number, .bool, .null:
        // Includes `additionalProperties: true`/`false` (the bool form) — a
        // permissive flag, not a nested schema.
        return currentDepth
    }
}

private extension MCPToolFilter {
    func includes(name: String) -> Bool {
        let normalizedSet = Set(names.map { $0.lowercased() })
        switch mode {
        case .allowAll:
            return true
        case .allowList:
            return normalizedSet.contains(name.lowercased())
        case .denyList:
            return normalizedSet.contains(name.lowercased()) == false
        }
    }
}
