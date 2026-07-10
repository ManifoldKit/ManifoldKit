import XCTest
import SwiftData
import ManifoldHardware
@testable import ManifoldPersistenceSwiftData

/// Wave 2 A1: rows persisted before the stable-code migration stored the
/// provider *display* string (`"OpenAI Responses"`, `"LM Studio"`) in
/// `providerRawValue`. The `provider` accessor now parses through
/// ``APIProvider/parse(_:)``, so those legacy rows must resolve to their real
/// provider instead of collapsing to `.custom`, and re-writes must persist the
/// stable code.
@MainActor
final class APIProviderStableCodeMigrationTests: XCTestCase {

    func test_legacyDisplayStrings_decodeToRealProvider() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        // Seed rows the way a pre-0.68 build wrote them: display strings in
        // providerRawValue (bypassing the setter, which now writes codes).
        let responses = APIEndpoint(name: "Legacy Responses", provider: .custom)
        responses.providerRawValue = "OpenAI Responses"
        let lmStudio = APIEndpoint(name: "Legacy LM Studio", provider: .custom)
        lmStudio.providerRawValue = "LM Studio"
        context.insert(responses)
        context.insert(lmStudio)
        try context.save()

        // Re-read through a fresh context to defeat any in-memory caching.
        let readContext = ModelContext(container)
        let rows = try readContext.fetch(FetchDescriptor<APIEndpoint>())
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })

        let readResponses = try XCTUnwrap(byName["Legacy Responses"])
        let readLMStudio = try XCTUnwrap(byName["Legacy LM Studio"])
        XCTAssertEqual(readResponses.provider, .openAIResponses,
                       "Legacy \"OpenAI Responses\" must not collapse to .custom")
        XCTAssertEqual(readLMStudio.provider, .lmStudio,
                       "Legacy \"LM Studio\" must not collapse to .custom")
    }

    func test_writePath_storesStableCode() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let endpoint = APIEndpoint(name: "New", provider: .openAIResponses)
        // The init already writes the code; assert it, then round-trip a setter.
        XCTAssertEqual(endpoint.providerRawValue, "openAIResponses")
        endpoint.provider = .lmStudio
        XCTAssertEqual(endpoint.providerRawValue, "lmStudio",
                       "Setter must persist the stable code, not the display string")
        context.insert(endpoint)
        try context.save()

        let readContext = ModelContext(container)
        let reread = try XCTUnwrap(
            try readContext.fetch(FetchDescriptor<APIEndpoint>()).first
        )
        XCTAssertEqual(reread.providerRawValue, "lmStudio")
        XCTAssertEqual(reread.provider, .lmStudio)
    }

    func test_legacyRow_fullRoundTrip_rewritesToStableCode() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let row = APIEndpoint(name: "Legacy OpenAI", provider: .custom)
        row.providerRawValue = "OpenAI"   // legacy display string
        context.insert(row)
        try context.save()

        // Read it back, assign the parsed provider back onto the row (what an
        // edit flow does), and confirm the on-disk raw value is now the code.
        let editContext = ModelContext(container)
        let editable = try XCTUnwrap(
            try editContext.fetch(FetchDescriptor<APIEndpoint>()).first
        )
        XCTAssertEqual(editable.provider, .openAI)
        editable.provider = editable.provider   // re-normalises the stored string
        try editContext.save()

        let finalContext = ModelContext(container)
        let final = try XCTUnwrap(
            try finalContext.fetch(FetchDescriptor<APIEndpoint>()).first
        )
        XCTAssertEqual(final.providerRawValue, "openAI",
                       "Re-writing a legacy row must migrate it to the stable code")
        XCTAssertEqual(final.provider, .openAI)
    }
}
