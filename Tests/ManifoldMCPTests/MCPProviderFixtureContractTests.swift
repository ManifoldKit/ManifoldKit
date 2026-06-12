import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldInference

final class MCPProviderFixtureContractTests: XCTestCase {
    private let providers = ["github", "linear", "notion"]

    func test_fixtureBundleContainsProviderContracts() throws {
        for provider in providers {
            _ = try fixtureURL(provider: provider, file: "server.json")
            _ = try fixtureURL(provider: provider, file: "initialize.result.json")
            _ = try fixtureURL(provider: provider, file: "tools.list.result.json")
        }
        // Sabotage: deleting any one of the Fixtures/Providers/<provider>/*.json files from the bundle resources would cause fixtureURL(provider:file:) to throw FixtureError.missingFixture, failing this test
    }

    func test_initializeFixtureReplayStartsSessionForEachProvider() async throws {
        let codec = MCPJSONRPCCodec(maxMessageBytes: 4 * 1024 * 1024, maxJSONNestingDepth: 32)

        for provider in providers {
            let server = try loadServerFixture(provider: provider)
            let initializeResult = try loadResultFixture(provider: provider, file: "initialize.result.json")
            let toolsResult = try loadResultFixture(provider: provider, file: "tools.list.result.json")

            let session = MCPSession(
                descriptor: try descriptor(from: server),
                transport: FixtureReplayTransport(codec: codec, initializeResult: initializeResult, toolsListResult: toolsResult),
                codec: codec,
                requestTimeout: .seconds(2),
                maxConcurrentRequests: 4
            )

            let capabilities = try await session.start()
            XCTAssertEqual(capabilities.protocolVersion, "2025-03-26", "initialize fixture protocol mismatch for \(provider)")
            XCTAssertFalse(capabilities.serverName.isEmpty, "initialize fixture missing serverInfo.name for \(provider)")

            let toolsResponse = try await session.sendRequest(method: "tools/list", params: nil)
            guard case .object(let toolsObject)? = toolsResponse,
                  case .array(let tools)? = toolsObject["tools"] else {
                XCTFail("tools/list replay did not return tools array for \(provider)")
                await session.close()
                continue
            }
            XCTAssertFalse(tools.isEmpty, "tools/list fixture has no tools for \(provider)")
            // Sabotage: stripping the "tools" key from any provider's tools.list.result.json fixture would make the guard-case pattern fail and reach XCTFail("tools/list replay did not return tools array for \(provider)")

            await session.close()
        }
    }

    func test_toolsListFixtureReplayRefreshesNamespacedTools() async throws {
        for provider in providers {
            let toolsResult = try loadResultFixture(provider: provider, file: "tools.list.result.json")
            let expectedNames = try extractToolNames(from: toolsResult).map { "\(provider)__\($0)" }.sorted()

            let source = MCPToolSource(
                serverID: UUID(),
                displayName: provider,
                capabilities: .init(),
                toolNamespace: provider,
                toolFilter: .allowAll,
                approvalPolicy: .perCall,
                listTools: { toolsResult },
                callTool: { _, _ in .object([:]) }
            )

            let delta = try await source.refreshToolsAndReturnDelta()
            XCTAssertEqual(delta.allNames.sorted(), expectedNames, "namespaced tool list drift for \(provider)")
            XCTAssertEqual(delta.removedNames, [], "Unexpected removed tools for \(provider)")
            // Sabotage: changing MCPToolSource.refreshToolsAndReturnDelta() to use "." as the namespace separator instead of "__" would produce names like "github.search" instead of "github__search", failing the delta.allNames equality check
        }
    }

    func test_serverFixturesMatchBuiltinCatalogContracts() throws {
        for provider in providers {
            let fixture = try loadServerFixture(provider: provider)
            let descriptor = descriptor(for: provider)

            XCTAssertEqual(fixture.provider, provider, "server fixture provider mismatch for \(provider)")
            XCTAssertEqual(fixture.catalog.id, descriptor.id.uuidString, "catalog UUID drift for \(provider)")
            XCTAssertEqual(fixture.catalog.displayName, descriptor.displayName, "display name drift for \(provider)")
            XCTAssertEqual(fixture.catalog.toolNamespace, descriptor.toolNamespace, "namespace drift for \(provider)")
            XCTAssertEqual(fixture.catalog.dataDisclosure, descriptor.dataDisclosure, "dataDisclosure drift for \(provider)")

            guard case let .streamableHTTP(endpoint, _) = descriptor.transport else {
                XCTFail("Expected streamableHTTP transport for \(provider)")
                continue
            }
            XCTAssertEqual(fixture.catalog.transport.type, "streamable-http", "transport type drift for \(provider)")
            XCTAssertEqual(fixture.catalog.transport.endpoint, endpoint.absoluteString, "transport endpoint drift for \(provider)")

            guard case let .oauth(oauth) = descriptor.authorization else {
                XCTFail("Expected OAuth auth for \(provider)")
                continue
            }
            XCTAssertEqual(fixture.catalog.oauth.issuer, oauth.authorizationServerIssuer?.absoluteString, "oauth issuer drift for \(provider)")
            XCTAssertEqual(fixture.catalog.oauth.scopes, oauth.scopes, "oauth scopes drift for \(provider)")
            XCTAssertEqual(fixture.catalog.oauth.redirectURI, oauth.redirectURI.absoluteString, "oauth redirectURI drift for \(provider)")
            // Sabotage: changing the UUID or endpoint URL in MCPCatalog.github/linear/notion without updating the corresponding server.json fixture would cause the catalog.id or catalog.transport.endpoint equality checks to fail
        }
    }

    private func fixtureURL(provider: String, file: String) throws -> URL {
        guard let base = Bundle.module.resourceURL else {
            throw FixtureError.missingFixture("Bundle.module.resourceURL")
        }
        let url = base
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("Providers", isDirectory: true)
            .appendingPathComponent(provider, isDirectory: true)
            .appendingPathComponent(file, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixtureError.missingFixture("Providers/\(provider)/\(file)")
        }
        return url
    }

    private func loadServerFixture(provider: String) throws -> ServerFixture {
        let data = try Data(contentsOf: try fixtureURL(provider: provider, file: "server.json"))
        return try JSONDecoder().decode(ServerFixture.self, from: data)
    }

    private func loadResultFixture(provider: String, file: String) throws -> JSONSchemaValue {
        let data = try Data(contentsOf: try fixtureURL(provider: provider, file: file))
        let object = try requireJSONObject(data: data, file: file, provider: provider)

        guard let version = object["jsonrpc"] as? String, version == "2.0" else {
            throw FixtureError.invalidFixture("\(provider)/\(file): jsonrpc must be '2.0'")
        }
        guard let result = object["result"] else {
            throw FixtureError.invalidFixture("\(provider)/\(file): missing result")
        }
        return try toJSONSchemaValue(result)
    }

    private func extractToolNames(from toolsResult: JSONSchemaValue) throws -> [String] {
        guard case .object(let root) = toolsResult,
              case .array(let values)? = root["tools"] else {
            throw FixtureError.invalidFixture("tools/list result missing tools array")
        }

        return try values.map { value in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"],
                  !name.isEmpty else {
                throw FixtureError.invalidFixture("tools/list tool item missing non-empty name")
            }
            return name
        }
    }

    private func descriptor(from fixture: ServerFixture) throws -> MCPServerDescriptor {
        guard let id = UUID(uuidString: fixture.catalog.id) else {
            throw FixtureError.invalidFixture("Invalid catalog UUID: \(fixture.catalog.id)")
        }
        guard let endpoint = URL(string: fixture.catalog.transport.endpoint) else {
            throw FixtureError.invalidFixture("Invalid endpoint URL: \(fixture.catalog.transport.endpoint)")
        }
        guard let redirectURI = URL(string: fixture.catalog.oauth.redirectURI) else {
            throw FixtureError.invalidFixture("Invalid redirect URL: \(fixture.catalog.oauth.redirectURI)")
        }
        return MCPServerDescriptor(
            id: id,
            displayName: fixture.catalog.displayName,
            transport: .streamableHTTP(endpoint: endpoint, headers: [:]),
            authorization: .oauth(.init(
                clientName: "ManifoldKit",
                scopes: fixture.catalog.oauth.scopes,
                redirectURI: redirectURI,
                authorizationServerIssuer: URL(string: fixture.catalog.oauth.issuer)
            )),
            toolNamespace: fixture.catalog.toolNamespace,
            resourceURL: endpoint,
            dataDisclosure: fixture.catalog.dataDisclosure
        )
    }

    private func descriptor(for provider: String) -> MCPServerDescriptor {
        switch provider {
        case "github":
            return MCPCatalog.github
        case "linear":
            return MCPCatalog.linear
        case "notion":
            return MCPCatalog.notion
        default:
            fatalError("Unhandled provider: \(provider)")
        }
    }

    private func requireJSONObject(data: Data, file: String, provider: String) throws -> [String: Any] {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any] else {
            throw FixtureError.invalidFixture("\(provider)/\(file): root must be an object")
        }
        return object
    }

    private func toJSONSchemaValue(_ raw: Any) throws -> JSONSchemaValue {
        switch raw {
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as NSNumber:
            return .number(value.doubleValue)
        case let value as String:
            return .string(value)
        case let values as [Any]:
            return .array(try values.map(toJSONSchemaValue))
        case let values as [String: Any]:
            var object: [String: JSONSchemaValue] = [:]
            object.reserveCapacity(values.count)
            for (key, value) in values {
                object[key] = try toJSONSchemaValue(value)
            }
            return .object(object)
        default:
            throw FixtureError.invalidFixture("Unsupported JSON value: \(String(describing: raw))")
        }
    }
}

private actor FixtureReplayTransport: MCPTransport {
    nonisolated let incomingMessages: AsyncThrowingStream<Data, Error>

    private let codec: MCPJSONRPCCodec
    private let initializeResult: JSONSchemaValue
    private let toolsListResult: JSONSchemaValue
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(codec: MCPJSONRPCCodec, initializeResult: JSONSchemaValue, toolsListResult: JSONSchemaValue) {
        self.codec = codec
        self.initializeResult = initializeResult
        self.toolsListResult = toolsListResult
        var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.incomingMessages = AsyncThrowingStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async throws {}

    func send(_ payload: Data) async throws {
        let message = try codec.decode(payload)
        guard case .request(let id, let method, _) = message else {
            return
        }

        let result: JSONSchemaValue
        switch method {
        case "initialize":
            result = initializeResult
        case "tools/list":
            result = toolsListResult
        default:
            return
        }

        continuation.yield(try codec.encode(.result(id: id, result: result)))
    }

    func close() async {
        continuation.finish()
    }
}

private enum FixtureError: Error {
    case missingFixture(String)
    case invalidFixture(String)
}

private struct ServerFixture: Decodable {
    let provider: String
    let catalog: Catalog

    struct Catalog: Decodable {
        let id: String
        let displayName: String
        let toolNamespace: String
        let dataDisclosure: String
        let transport: Transport
        let oauth: OAuth

        struct Transport: Decodable {
            let type: String
            let endpoint: String
        }

        struct OAuth: Decodable {
            let issuer: String
            let scopes: [String]
            let redirectURI: String
        }
    }
}
