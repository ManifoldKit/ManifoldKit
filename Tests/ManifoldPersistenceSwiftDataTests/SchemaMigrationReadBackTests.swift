// Validates the Phase 2 acceptance criterion from the runtime-ports plan
// (docs/plans/archive/runtime-ports-phase-1-2.md, removed in a 2026-07
// docs/plans hygiene pass — see git history):
// "A read-back test opens a v0.13.x-era store fixture and asserts data integrity."
//
// v0.13.x shipped ManifoldSchemaV3, before the V4 sampler-penalty columns and the
// V5 RagDocument table were added. This test proves that entity names are unaffected
// by the module reorganisation (ManifoldCore → ManifoldPersistenceSwiftData) and that
// the full V3→V4→V5 migration chain preserves every pre-refactor row verbatim.
//
// The fixture is generated in-process (not a committed binary SQLite blob) so it stays
// resilient to WAL-mode changes, VACUUM layout differences, and SwiftData internal
// format bumps. An OOD nonce embedded in each record falsifies the assertions if the
// migration silently drops or corrupts rows.

import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference

final class SchemaMigrationReadBackTests: XCTestCase {

    // MARK: - Full-chain migration read-back

    /// Seeds a V3 store with a ``ManifoldSchemaV9.ChatSession``, a ``ManifoldSchemaV9.ChatMessage``, a
    /// ``SamplerPreset``, and an ``APIEndpoint``, then opens the same file with
    /// the current ``ModelContainerFactory`` (schema V5, plan V3→V4→V5) and
    /// asserts every record survives the two-hop migration intact.
    ///
    /// This is the Phase 2 acceptance criterion read-back test: it confirms that
    /// the physical-target split (ManifoldCore → ManifoldPersistenceSwiftData)
    /// does not alter SwiftData entity names and that pre-refactor stores remain
    /// readable without data loss.
    func test_v3StoreFixture_migratesCleanlyToCurrentSchema_viaModelContainerFactory() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifold-v3-readback-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        // OOD nonces — survive migration and falsify assertions when a row is dropped.
        let sessionNonce   = "§READBACK-SESSION§\(UUID().uuidString.prefix(8))"
        let messageNonce   = "§READBACK-MSG§\(UUID().uuidString.prefix(8))"
        let presetNonce    = "§READBACK-PRESET§\(UUID().uuidString.prefix(8))"
        let endpointNonce  = "§READBACK-ENDPOINT§\(UUID().uuidString.prefix(8))"

        let sessionID:  UUID
        let messageID:  UUID
        let presetID:   UUID
        let endpointID: UUID

        // --- Step 1: Seed a V3 store ---
        //
        // Open with no migration plan so SwiftData commits V3 metadata and does not
        // auto-advance. Scoped block ensures the container (and its WAL lock) is
        // released before the V5 open below.
        do {
            let v3Container = try ModelContainer(
                for: Schema(versionedSchema: ManifoldSchemaV3.self),
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let ctx = ModelContext(v3Container)

            let session = ManifoldSchemaV3.ChatSession(title: sessionNonce)
            ctx.insert(session)
            sessionID = session.id

            let message = ManifoldSchemaV3.ChatMessage(
                role: .user,
                content: messageNonce,
                sessionID: session.id
            )
            ctx.insert(message)
            messageID = message.id

            let preset = ManifoldSchemaV3.SamplerPreset(
                name: presetNonce,
                temperature: 0.6,
                topP: 0.88,
                repeatPenalty: 1.05
            )
            ctx.insert(preset)
            presetID = preset.id

            let endpoint = ManifoldSchemaV3.APIEndpoint(
                name: endpointNonce,
                provider: .openAI
            )
            ctx.insert(endpoint)
            endpointID = endpoint.id

            try ctx.save()
            // Container released here — WAL lock freed.
        }

        // --- Step 2: Open with the current schema via ModelContainerFactory ---
        //
        // ModelContainerFactory.makeContainer applies ManifoldMigrationPlan (V3→V4→V5),
        // the same path any user who shipped on v0.13.x would exercise on upgrade.
        let migratedContainer = try ModelContainerFactory.makeContainer(
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let ctx = ModelContext(migratedContainer)

        // --- ChatSession (fetched as PersistedChatSession — the *current*
        // schema's ChatSession type, now V13 — since ModelContainerFactory
        // always migrates all the way to the current schema, not just V5) ---
        let sessions = try ctx.fetch(FetchDescriptor<PersistedChatSession>(
            predicate: #Predicate { $0.id == sessionID }
        ))
        XCTAssertEqual(sessions.count, 1,
            "ChatSession must survive the full V3→current migration chain (id: \(sessionID))")
        let migratedSession = try XCTUnwrap(sessions.first)
        XCTAssertEqual(migratedSession.title, sessionNonce,
            "ChatSession.title must be preserved verbatim through migration")

        // --- ManifoldSchemaV9.ChatMessage ---
        let messages = try ctx.fetch(FetchDescriptor<ManifoldSchemaV9.ChatMessage>(
            predicate: #Predicate { $0.id == messageID }
        ))
        XCTAssertEqual(messages.count, 1,
            "ManifoldSchemaV9.ChatMessage must survive V3→V5 migration (id: \(messageID))")
        let migratedMessage = try XCTUnwrap(messages.first)
        XCTAssertEqual(migratedMessage.content, messageNonce,
            "ManifoldSchemaV9.ChatMessage.content must be preserved verbatim through migration")
        XCTAssertEqual(migratedMessage.role, .user,
            "ManifoldSchemaV9.ChatMessage.role must be preserved through migration")
        XCTAssertEqual(migratedMessage.sessionID, sessionID,
            "ManifoldSchemaV9.ChatMessage.sessionID must be preserved through migration")

        // --- SamplerPreset ---
        // V4 added optional penalty columns; they must be nil for a V3 row.
        let presets = try ctx.fetch(FetchDescriptor<SamplerPreset>(
            predicate: #Predicate { $0.id == presetID }
        ))
        XCTAssertEqual(presets.count, 1,
            "SamplerPreset must survive V3→V5 migration (id: \(presetID))")
        let migratedPreset = try XCTUnwrap(presets.first)
        XCTAssertEqual(migratedPreset.name, presetNonce,
            "SamplerPreset.name must be preserved verbatim through migration")
        XCTAssertEqual(migratedPreset.temperature, 0.6, accuracy: 0.001)
        XCTAssertEqual(migratedPreset.topP, 0.88, accuracy: 0.001)
        XCTAssertEqual(migratedPreset.repeatPenalty, 1.05, accuracy: 0.001)
        // V4-only optional fields must be nil — column defaults, not garbage.
        XCTAssertNil(migratedPreset.presencePenalty,
            "presencePenalty must be nil after migrating a V3 SamplerPreset")
        XCTAssertNil(migratedPreset.frequencyPenalty,
            "frequencyPenalty must be nil after migrating a V3 SamplerPreset")
        XCTAssertNil(migratedPreset.repetitionContextSize,
            "repetitionContextSize must be nil after migrating a V3 SamplerPreset")
        XCTAssertNil(migratedPreset.presenceContextSize,
            "presenceContextSize must be nil after migrating a V3 SamplerPreset")
        XCTAssertNil(migratedPreset.frequencyContextSize,
            "frequencyContextSize must be nil after migrating a V3 SamplerPreset")

        // --- APIEndpoint ---
        let endpoints = try ctx.fetch(FetchDescriptor<APIEndpoint>(
            predicate: #Predicate { $0.id == endpointID }
        ))
        XCTAssertEqual(endpoints.count, 1,
            "APIEndpoint must survive V3→V5 migration (id: \(endpointID))")
        let migratedEndpoint = try XCTUnwrap(endpoints.first)
        XCTAssertEqual(migratedEndpoint.name, endpointNonce,
            "APIEndpoint.name must be preserved verbatim through migration")
        XCTAssertEqual(migratedEndpoint.provider, .openAI,
            "APIEndpoint.provider must be preserved through migration")
        XCTAssertTrue(migratedEndpoint.isEnabled,
            "APIEndpoint.isEnabled must remain true after migration")

        // --- V5 RagDocument table is present and empty ---
        // This confirms the lightweight V4→V5 stage ran without clobbering V3/V4 rows.
        let ragDocs = try ctx.fetch(FetchDescriptor<RagDocument>())
        XCTAssertTrue(ragDocs.isEmpty,
            "RagDocument table must be empty after migrating a V3 store (no RAG rows were seeded)")
    }
}
