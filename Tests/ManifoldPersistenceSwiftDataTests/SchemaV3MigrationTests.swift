import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference

/// Cross-version migration test: proves that a V3 store seeded in-process
/// opens and reads correctly through the V3→V4 stage of the migration plan.
///
/// This deliberately pins just the V3→V4 stage in isolation. The live plan now
/// runs the full V3→V9 chain (`ManifoldMigrationPlan`); end-to-end coverage of
/// the whole chain lives in `SchemaMigrationTests`.
///
/// The fixture is generated at test time (not a committed binary SQLite blob)
/// because binary fixtures are fragile against WAL-mode changes, VACUUM layout
/// differences, and SwiftData internal format bumps. Generating in-process also
/// lets us embed OOD nonces that survive migration and falsify the assertions
/// when the migration silently drops rows.
///
/// Gated by `RUN_OPERATIONAL_TESTS=1` to keep per-PR CI fast.
final class SchemaV3MigrationTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Gate: only run in operational CI or locally when opt-in.
        // `try?` here would swallow XCTSkip and run the test anyway.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_OPERATIONAL_TESTS"] == "1",
            "Set RUN_OPERATIONAL_TESTS=1 to run migration tests"
        )
    }

    // MARK: - Migration test

    /// Seeds a V3 store with a `ChatSession` and `ChatMessage` carrying OOD
    /// nonces, then re-opens the same file under the V4 migration plan and
    /// asserts both records survive intact.
    ///
    /// V3→V4 is a lightweight migration that adds optional `SamplerPreset`
    /// columns. `ChatSession` and `ChatMessage` are structurally identical
    /// across the two versions — this test confirms the migration plan leaves
    /// them untouched.
    func test_v3Store_migratesCleanlyToV4_preservingSessionAndMessages() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("basechat-v3-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let sessionNonce = "§V3-SESSION§\(UUID().uuidString.prefix(8))"
        let messageNonce = "§V3-MSG§\(UUID().uuidString.prefix(8))"

        // --- Step 1: Seed a V3 store ---
        //
        // Open with no migration plan so SwiftData commits V3 metadata and
        // does not auto-advance to V4. Use a scoped block to ensure the
        // container (and its WAL lock) is released before the V4 open.
        let sessionID: UUID
        let messageID: UUID
        do {
            let v3Config = ModelConfiguration(url: storeURL)
            let v3Container = try ModelContainer(
                for: Schema(versionedSchema: ManifoldSchemaV3.self),
                configurations: [v3Config]
            )
            let v3Context = ModelContext(v3Container)

            let session = ManifoldSchemaV3.ChatSession(title: sessionNonce)
            v3Context.insert(session)
            sessionID = session.id

            // V3 ChatMessage init takes `role: MessageRole, content: String, sessionID: UUID`.
            let message = ManifoldSchemaV3.ChatMessage(
                role: .user,
                content: messageNonce,
                sessionID: session.id
            )
            v3Context.insert(message)
            messageID = message.id

            try v3Context.save()
            // Container goes out of scope here, releasing the WAL lock.
        }

        // --- Step 2: Re-open targeting V4 through the migration plan (V3→V4 stage) ---
        let v4Config = ModelConfiguration(url: storeURL)
        let v4Container = try ModelContainer(
            for: Schema(versionedSchema: ManifoldSchemaV4.self),
            migrationPlan: ManifoldMigrationPlan.self,
            configurations: [v4Config]
        )
        let v4Context = ModelContext(v4Container)

        // Assert the session survived migration with its title nonce intact.
        let sessions = try v4Context.fetch(FetchDescriptor<ManifoldSchemaV4.ChatSession>(
            predicate: #Predicate { $0.id == sessionID }
        ))
        XCTAssertEqual(sessions.count, 1,
            "Exactly one session with id \(sessionID) must survive V3→V4 migration")
        let migratedSession = try XCTUnwrap(sessions.first,
            "Session with nonce '\(sessionNonce)' must survive migration")
        XCTAssertEqual(migratedSession.title, sessionNonce,
            "Session title nonce must be preserved verbatim after migration")

        // Assert the message survived migration with its content nonce intact.
        let messages = try v4Context.fetch(FetchDescriptor<ManifoldSchemaV4.ChatMessage>(
            predicate: #Predicate { $0.id == messageID }
        ))
        XCTAssertEqual(messages.count, 1,
            "Exactly one message with id \(messageID) must survive V3→V4 migration")
        let migratedMessage = try XCTUnwrap(messages.first,
            "Message with nonce '\(messageNonce)' must survive migration")
        XCTAssertEqual(migratedMessage.content, messageNonce,
            "Message content nonce must be preserved verbatim after migration")
        XCTAssertEqual(migratedMessage.role, .user,
            "Message role must be preserved after migration")
        XCTAssertEqual(migratedMessage.sessionID, sessionID,
            "Message sessionID must be preserved after migration")
    }

    /// Verifies the V4 `SamplerPreset` optional penalty columns (`presencePenalty`,
    /// `frequencyPenalty`, context-size fields) are `nil` for a preset written
    /// before the migration — confirming the lightweight migration left them
    /// at their column default rather than populating them with garbage.
    func test_v3SamplerPreset_migratesWithNilOptionalPenaltyFields() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("basechat-v3-preset-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let presetID: UUID
        do {
            let v3Config = ModelConfiguration(url: storeURL)
            let v3Container = try ModelContainer(
                for: Schema(versionedSchema: ManifoldSchemaV3.self),
                configurations: [v3Config]
            )
            let v3Context = ModelContext(v3Container)
            let preset = ManifoldSchemaV3.SamplerPreset(
                name: "LegacyPreset",
                temperature: 0.5,
                topP: 0.85,
                repeatPenalty: 1.15
            )
            v3Context.insert(preset)
            presetID = preset.id
            try v3Context.save()
        }

        let v4Config = ModelConfiguration(url: storeURL)
        let v4Container = try ModelContainer(
            for: Schema(versionedSchema: ManifoldSchemaV4.self),
            migrationPlan: ManifoldMigrationPlan.self,
            configurations: [v4Config]
        )
        let v4Context = ModelContext(v4Container)

        let presets = try v4Context.fetch(FetchDescriptor<ManifoldSchemaV4.SamplerPreset>(
            predicate: #Predicate { $0.id == presetID }
        ))
        XCTAssertEqual(presets.count, 1,
            "SamplerPreset must survive V3→V4 migration")
        let migratedPreset = try XCTUnwrap(presets.first)

        XCTAssertEqual(migratedPreset.name, "LegacyPreset")
        XCTAssertEqual(migratedPreset.temperature, 0.5, accuracy: 0.001)
        XCTAssertEqual(migratedPreset.topP, 0.85, accuracy: 0.001)
        XCTAssertEqual(migratedPreset.repeatPenalty, 1.15, accuracy: 0.001)

        // V4-only optional fields must be nil after migrating a V3 row.
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
    }
}
