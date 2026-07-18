import XCTest
@testable import ManifoldUIModelManagement
import ManifoldInference
import ManifoldHardware

/// Pins ``ModelSwitcher``'s presentation-layer merge (issue #2307 Unit 2 §L3,
/// `docs/UI-REFRESH-2026.md` §5's "the one structural change"): local models
/// and cloud endpoints co-list in one row set, the existing mutual-exclusion
/// selection model is preserved (never both selected), capability glyphs
/// come from data (not marketing), and unavailable/faulted rows dim with a
/// reason string rather than disappearing silently.
final class ModelSwitcherTests: XCTestCase {

    private func makeModel(
        name: String,
        type: ModelType = .gguf,
        fileSize: UInt64 = 4_000_000_000,
        mmproj: URL? = nil,
        reasoning: Bool = false,
        chatTemplateRaw: String? = nil
    ) -> ModelInfo {
        ModelInfo(
            name: name,
            fileName: "\(name).gguf",
            url: URL(fileURLWithPath: "/tmp/\(name).gguf"),
            fileSize: fileSize,
            modelType: type,
            mmprojURL: mmproj,
            chatTemplateRaw: chatTemplateRaw,
            curatedSupportsReasoning: reasoning ? true : nil
        )
    }

    private func makeEndpoint(name: String) -> APIEndpointRecord {
        APIEndpointRecord(provider: .openAI, baseURL: "https://api.openai.com", modelName: name)
    }

    // MARK: - Union / co-listing

    func test_rows_coListsModelsAndEndpoints() {
        let model = makeModel(name: "Local")
        let endpoint = makeEndpoint(name: "Cloud")
        let rows = ModelSwitcher.rows(
            models: [model],
            endpoints: [endpoint],
            selectedModelID: nil,
            selectedEndpointID: nil,
            physicalMemoryBytes: 16_000_000_000,
            compatibility: { _ in .supported }
        )
        XCTAssertEqual(rows.count, 2, "Local models and cloud endpoints must co-list in one row set")
        XCTAssertTrue(rows.contains { if case .model = $0.entry { return true }; return false })
        XCTAssertTrue(rows.contains { if case .endpoint = $0.entry { return true }; return false })
    }

    // MARK: - Selection mutual exclusion preserved

    func test_rows_preservesMutualExclusionSelection() {
        let model = makeModel(name: "Local")
        let endpoint = makeEndpoint(name: "Cloud")
        let rows = ModelSwitcher.rows(
            models: [model],
            endpoints: [endpoint],
            selectedModelID: model.id,
            selectedEndpointID: nil,
            physicalMemoryBytes: 16_000_000_000,
            compatibility: { _ in .supported }
        )
        let modelRow = rows.first { if case .model = $0.entry { return true }; return false }!
        let endpointRow = rows.first { if case .endpoint = $0.entry { return true }; return false }!
        XCTAssertTrue(modelRow.isSelected)
        XCTAssertFalse(endpointRow.isSelected, "An endpoint row must never read selected while a local model is the active selection")
    }

    func test_rows_endpointSelected_modelNotSelected() {
        let model = makeModel(name: "Local")
        let endpoint = makeEndpoint(name: "Cloud")
        let rows = ModelSwitcher.rows(
            models: [model],
            endpoints: [endpoint],
            selectedModelID: nil,
            selectedEndpointID: endpoint.id,
            physicalMemoryBytes: 16_000_000_000,
            compatibility: { _ in .supported }
        )
        let modelRow = rows.first { if case .model = $0.entry { return true }; return false }!
        let endpointRow = rows.first { if case .endpoint = $0.entry { return true }; return false }!
        XCTAssertFalse(modelRow.isSelected)
        XCTAssertTrue(endpointRow.isSelected)
    }

    // MARK: - Capability glyphs from data, not marketing

    func test_rows_capabilityGlyphs_derivedFromModelData() {
        let model = makeModel(
            name: "Vision",
            mmproj: URL(fileURLWithPath: "/tmp/mmproj.gguf"),
            reasoning: true
        )
        let rows = ModelSwitcher.rows(
            models: [model], endpoints: [], selectedModelID: nil, selectedEndpointID: nil,
            physicalMemoryBytes: 16_000_000_000, compatibility: { _ in .supported }
        )
        XCTAssertTrue(rows[0].capabilityGlyphs.contains(.reasoning))
        XCTAssertTrue(rows[0].capabilityGlyphs.contains(.vision))
        XCTAssertFalse(rows[0].capabilityGlyphs.contains(.tools), "No tools claim was supplied — a claim must render as a claim, never assumed")
    }

    func test_rows_endpointRows_carryNoCapabilityGlyphs() {
        let endpoint = makeEndpoint(name: "Cloud")
        let rows = ModelSwitcher.rows(
            models: [], endpoints: [endpoint], selectedModelID: nil, selectedEndpointID: nil,
            physicalMemoryBytes: 16_000_000_000, compatibility: { _ in .supported }
        )
        XCTAssertTrue(rows[0].capabilityGlyphs.isEmpty)
    }

    // MARK: - Backend-availability dimming (distinct from device fit)

    func test_rows_dimmedWhenBackendUnavailable() {
        let model = makeModel(name: "Unavailable")
        let rows = ModelSwitcher.rows(
            models: [model], endpoints: [], selectedModelID: nil, selectedEndpointID: nil,
            physicalMemoryBytes: 16_000_000_000,
            compatibility: { _ in .unsupported(reason: "No backend registered") }
        )
        XCTAssertFalse(rows[0].isAvailable)
        XCTAssertEqual(rows[0].unavailableReason, "No backend registered")
    }

    // MARK: - Endpoint faults

    func test_rows_faultedEndpoint_surfacesFaultAndDims() {
        let endpoint = makeEndpoint(name: "Faulty")
        let rows = ModelSwitcher.rows(
            models: [], endpoints: [endpoint], selectedModelID: nil, selectedEndpointID: nil,
            physicalMemoryBytes: 16_000_000_000, compatibility: { _ in .supported },
            endpointFault: { _ in "Invalid API key" }
        )
        XCTAssertEqual(rows[0].endpointFault, "Invalid API key")
        XCTAssertFalse(rows[0].isAvailable, "A faulted endpoint must dim like an unavailable local model")
    }

    // MARK: - Fit dot: qualitative, absent for cloud

    func test_rows_fitVerdict_nilForEndpoints() {
        let endpoint = makeEndpoint(name: "Cloud")
        let rows = ModelSwitcher.rows(
            models: [], endpoints: [endpoint], selectedModelID: nil, selectedEndpointID: nil,
            physicalMemoryBytes: 16_000_000_000, compatibility: { _ in .supported }
        )
        XCTAssertNil(rows[0].fitVerdict, "Cloud rows render the accent tint, not a fit dot")
    }

    func test_rows_fitVerdict_goodForFoundationRegardlessOfSize() {
        let model = makeModel(name: "Foundation", type: .foundation, fileSize: 0)
        let rows = ModelSwitcher.rows(
            models: [model], endpoints: [], selectedModelID: nil, selectedEndpointID: nil,
            physicalMemoryBytes: 4_000_000_000, compatibility: { _ in .supported }
        )
        XCTAssertEqual(rows[0].fitVerdict, .good)
    }

    func test_rows_fitVerdict_poorWhenModelTooLargeForDevice() {
        let model = makeModel(name: "Huge", fileSize: 100_000_000_000)
        let rows = ModelSwitcher.rows(
            models: [model], endpoints: [], selectedModelID: nil, selectedEndpointID: nil,
            physicalMemoryBytes: 4_000_000_000, compatibility: { _ in .supported }
        )
        XCTAssertEqual(rows[0].fitVerdict, .poor)
    }

    func test_rows_fitVerdict_unknownWhenSizeUnknown() {
        let model = makeModel(name: "SizeUnknown", fileSize: 0)
        let rows = ModelSwitcher.rows(
            models: [model], endpoints: [], selectedModelID: nil, selectedEndpointID: nil,
            physicalMemoryBytes: 16_000_000_000, compatibility: { _ in .supported }
        )
        XCTAssertEqual(rows[0].fitVerdict, .unknown)
    }

    // MARK: - Download status pass-through

    func test_rows_carriesDownloadStatus() {
        let model = makeModel(name: "Downloading")
        let rows = ModelSwitcher.rows(
            models: [model], endpoints: [], selectedModelID: nil, selectedEndpointID: nil,
            physicalMemoryBytes: 16_000_000_000, compatibility: { _ in .supported },
            downloadStatus: { _ in .downloading(progress: 0.5, bytesDownloaded: 500, totalBytes: 1000) }
        )
        guard case .downloading(let progress, _, _)? = rows[0].downloadStatus else {
            return XCTFail("Expected a .downloading status to pass through")
        }
        XCTAssertEqual(progress, 0.5)
    }
}
