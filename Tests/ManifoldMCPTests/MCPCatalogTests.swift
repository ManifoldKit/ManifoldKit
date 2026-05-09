#if MCP
import XCTest
import ManifoldMCP

final class MCPCatalogTests: XCTestCase {
    #if MCPBuiltinCatalog
    func test_eachCatalogEntryEndpointIsHTTPS() {
        for descriptor in MCPCatalog.all {
            if case .streamableHTTP(let endpoint, _) = descriptor.transport {
                XCTAssertEqual(endpoint.scheme, "https", "\(descriptor.displayName) uses non-HTTPS endpoint")
            }
        }
        // Sabotage: changing one endpoint to http:// would fail this test
    }

    func test_descriptorRoundtripCodable() throws {
        for descriptor in MCPCatalog.all {
            let data = try JSONEncoder().encode(descriptor)
            let decoded = try JSONDecoder().decode(MCPServerDescriptor.self, from: data)
            XCTAssertEqual(decoded, descriptor)
        }
    }

    func test_descriptorScopesNonEmpty() {
        for descriptor in MCPCatalog.all {
            if case .oauth(let oauth) = descriptor.authorization {
                XCTAssertFalse(oauth.scopes.isEmpty, "\(descriptor.displayName) has empty scopes")
            }
        }
    }

    func test_dataDisclosureNonEmpty() {
        for descriptor in MCPCatalog.all {
            XCTAssertFalse(descriptor.dataDisclosure.isEmpty, "\(descriptor.displayName) missing dataDisclosure")
        }
    }

    func test_noTwoDescriptorsShareID() {
        let ids = MCPCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate catalog entry IDs found")
    }

    func test_universalLinkOAuthRedirectBaseURLOverridesCatalogCallbacks() throws {
        let descriptors = try MCPCatalog.all(oauthRedirectBaseURL: URL(string: "https://demo.manifoldkit.dev/oauth")!)
        XCTAssertEqual(descriptors.count, MCPCatalog.all.count)

        for descriptor in descriptors {
            guard case .oauth(let oauth) = descriptor.authorization else {
                XCTFail("\(descriptor.displayName) missing OAuth descriptor")
                continue
            }

            XCTAssertEqual(oauth.redirectURI.scheme, "https")
            XCTAssertEqual(oauth.redirectURI.host, "demo.manifoldkit.dev")
            XCTAssertTrue(oauth.redirectURI.path.hasPrefix("/oauth/mcp/"))
            XCTAssertTrue(oauth.redirectURI.path.hasSuffix("/callback"))
        }
    }

    func test_universalLinkOAuthRedirectBaseURLRejectsNonHTTPS() {
        XCTAssertThrowsError(try MCPCatalog.all(oauthRedirectBaseURL: URL(string: "basechat://oauth")!)) { error in
            guard case MCPError.malformedMetadata = error else {
                XCTFail("Expected malformedMetadata, got \(error)")
                return
            }
        }
    }
    #endif
}
#endif
