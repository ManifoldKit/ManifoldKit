#if CloudSaaS || Ollama
import XCTest
@testable import ManifoldInference

/// Guards against CI regressions in the cloud-tier contract suite runtime.
///
/// Re-executes the same fixture-loading and payload-parsing work that
/// ``InferenceBackendContractTests`` does and asserts the total wall-clock
/// time stays under 15 seconds. The cloud-tier only runs fixture I/O and
/// in-process parsing — no network calls — so 15 seconds is a generous
/// ceiling that should absorb any CI load variance while still catching a
/// pathological regression (e.g. reading an accidentally huge fixture file
/// in a loop).
///
/// Gated on `#if CloudSaaS || Ollama` because that is the same condition
/// wrapping ``InferenceBackendContractTests``. Without cloud traits, there
/// are no cloud participants and nothing to measure.
final class ContractSuiteRuntimeBudgetTest: XCTestCase {

    func test_cloudTierContractSuite_completesUnder15Seconds() throws {
        let clock = ContinuousClock()
        let start = clock.now

        // Re-run the same fixture corpus that InferenceBackendContractTests
        // exercises: load and parse every `response.sse` / `response.ndjson`
        // and `expected.jsonl` file for each cloud participant.
        let participants = try buildParticipants()
        for p in participants {
            // Streaming/simple-prompt — always present for all participants.
            _ = try loadPayloads(participant: p, scenario: "streaming/simple-prompt")
            _ = try fixtureContents(for: p, scenario: "streaming/simple-prompt", file: "expected.jsonl")
            // Usage/basic — always present.
            _ = try loadPayloads(participant: p, scenario: "usage/basic")
            // Tool-calls/simple — always present for tool-calling participants.
            if p.supportsToolCalling {
                _ = try loadPayloads(participant: p, scenario: "tool-calls/simple")
            }
        }

        let elapsed = clock.now - start
        // ContinuousClock.Duration has no direct comparison to Double in Swift
        // 6.0; use .components to extract seconds.
        let elapsedSeconds = Double(elapsed.components.seconds) +
                             Double(elapsed.components.attoseconds) / 1e18
        XCTAssertLessThan(
            elapsedSeconds,
            15.0,
            """
            Cloud-tier contract suite took \(String(format: "%.2f", elapsedSeconds))s — \
            exceeds 15s budget. Investigate large fixture files or expensive parsing paths.
            """
        )
    }

    // MARK: - Budget-test helpers

    /// Lightweight participant descriptor used only for budget accounting.
    private struct BudgetParticipant {
        let label: String
        let fixtureDirectory: String
        let wireFormat: WireFormat
        let supportsToolCalling: Bool

        enum WireFormat {
            case sse, ndjson
            var fileName: String {
                switch self {
                case .sse: return "response.sse"
                case .ndjson: return "response.ndjson"
                }
            }
        }
    }

    private func buildParticipants() throws -> [BudgetParticipant] {
        var list: [BudgetParticipant] = []
        #if CloudSaaS
        list.append(BudgetParticipant(
            label: "openai.chat_completions",
            fixtureDirectory: "openai",
            wireFormat: .sse,
            supportsToolCalling: true
        ))
        list.append(BudgetParticipant(
            label: "openai.responses",
            fixtureDirectory: "openai_responses",
            wireFormat: .sse,
            supportsToolCalling: true
        ))
        list.append(BudgetParticipant(
            label: "anthropic.messages",
            fixtureDirectory: "claude",
            wireFormat: .sse,
            supportsToolCalling: true
        ))
        #endif
        #if Ollama
        list.append(BudgetParticipant(
            label: "ollama.chat",
            fixtureDirectory: "ollama",
            wireFormat: .ndjson,
            supportsToolCalling: true
        ))
        #endif
        return list
    }

    private func loadPayloads(participant: BudgetParticipant, scenario: String) throws -> [String] {
        let url = try fixtureURL(for: participant, scenario: scenario, file: participant.wireFormat.fileName)
        let raw = try String(contentsOf: url, encoding: .utf8)
        switch participant.wireFormat {
        case .sse:
            return raw.components(separatedBy: "\n").compactMap { line -> String? in
                guard line.hasPrefix("data: ") else { return nil }
                let payload = String(line.dropFirst("data: ".count))
                return payload == "[DONE]" ? nil : payload
            }
        case .ndjson:
            return raw.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
    }

    private func fixtureContents(
        for participant: BudgetParticipant,
        scenario: String,
        file: String
    ) throws -> String {
        let url = try fixtureURL(for: participant, scenario: scenario, file: file)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fixtureURL(
        for participant: BudgetParticipant,
        scenario: String,
        file: String,
        filePath: StaticString = #filePath
    ) throws -> URL {
        let root = try Self.locateFixturesRoot(filePath: filePath)
        return root
            .appendingPathComponent("backends")
            .appendingPathComponent(participant.fixtureDirectory)
            .appendingPathComponent(scenario)
            .appendingPathComponent(file)
    }

    private static func locateFixturesRoot(filePath: StaticString) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests/Fixtures")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "ContractSuiteRuntimeBudgetTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/ from #filePath"
        ])
    }
}
#endif
