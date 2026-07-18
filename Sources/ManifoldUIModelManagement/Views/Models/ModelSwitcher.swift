import Foundation
import ManifoldHardware
import ManifoldInference

/// One row in the unified model switcher: either a locally-discoverable model
/// or a configured cloud endpoint (spec §5, `docs/UI-REFRESH-2026.md`, issue
/// #2307 Unit 2 §L3).
///
/// Local models (``ModelInfo``, via `ModelRegistry.availableModels`) and cloud
/// endpoints (``APIEndpointRecord``, via `EndpointStore`) are mutually
/// exclusive selections today (`ModelRegistry.swift:37-55`'s synchronous
/// endpoint-clear on model selection) but were never co-presented in one
/// list — this type is the presentation-layer union spec §5 calls "the one
/// structural change." It does not alter the selection model itself.
public enum ModelSwitcherEntry: Identifiable, Sendable, Equatable {
    case model(ModelInfo)
    case endpoint(APIEndpointRecord)

    public var id: String {
        switch self {
        case .model(let model): return "model-\(model.id.uuidString)"
        case .endpoint(let endpoint): return "endpoint-\(endpoint.id.uuidString)"
        }
    }

    /// Display name — ``ModelInfo/name`` or ``APIEndpointRecord/name``.
    public var displayName: String {
        switch self {
        case .model(let model): return model.name
        case .endpoint(let endpoint): return endpoint.name
        }
    }
}

/// Capability glyphs the switcher renders per spec §5 rule 2 — "capability
/// glyphs come from data, not marketing... a claim renders as a claim."
public enum ModelSwitcherCapabilityGlyph: String, Sendable, CaseIterable {
    /// ✦ — sourced from ``ModelInfo/supportsReasoning``.
    case reasoning
    /// ⚙ — sourced from ``ModelInfo/toolCallClaim``'s `toolsExpressible`.
    case tools
    /// ◎ — sourced from ``ModelInfo/mmprojURL`` being non-`nil`.
    case vision

    /// The glyph character rendered in the switcher row.
    public var glyph: String {
        switch self {
        case .reasoning: return "✦"
        case .tools: return "⚙"
        case .vision: return "◎"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .reasoning: return "Supports reasoning"
        case .tools: return "Supports tool calling"
        case .vision: return "Supports vision"
        }
    }
}

/// The qualitative device-fit signal (spec §5 rule 1): "one fitness signal
/// per row, qualitative... raw tok/s never appears in the switcher." Cloud
/// endpoint rows carry `fitVerdict == nil` on ``ModelSwitcherRow`` — the
/// caller renders the accent tint instead of a fit dot for those, per the
/// spec's "accent for cloud" rule.
public enum ModelSwitcherFitVerdict: Sendable, Equatable {
    /// Comfortably fits (or is system-managed, e.g. Apple Foundation Models).
    case good
    /// Borderline — fits only at a reduced size estimate.
    case warn
    /// Will not fit this device.
    case poor
    /// Size unknown — neither a green nor a red claim can be made honestly.
    case unknown
}

/// One row's full presentation state, computed by
/// ``ModelSwitcher/rows(models:endpoints:selectedModelID:selectedEndpointID:physicalMemoryBytes:compatibility:downloadStatus:endpointFault:)``.
///
/// Carries only presentation-layer data — no view code — so it is testable
/// without standing up SwiftUI.
public struct ModelSwitcherRow: Identifiable, Sendable {
    public let entry: ModelSwitcherEntry
    public let isSelected: Bool

    /// `nil` for cloud endpoint rows — see ``ModelSwitcherFitVerdict``'s doc
    /// comment.
    public let fitVerdict: ModelSwitcherFitVerdict?
    public let capabilityGlyphs: [ModelSwitcherCapabilityGlyph]

    /// `false` when the backend/provider for this entry has no registered
    /// factory in this build (spec §5 rule 3: "dimmed row + reason string" —
    /// a distinct failure mode from device-fit).
    public let isAvailable: Bool
    public let unavailableReason: String?

    /// Inline download progress for a not-yet-downloaded local model. `nil`
    /// for endpoints and for models that are already on disk.
    public let downloadStatus: DownloadStatus?

    /// A faulted cloud endpoint's error message, when the caller supplies
    /// one (e.g. from a prior connection attempt). `nil` for local models.
    public let endpointFault: String?

    public var id: String { entry.id }

    public init(
        entry: ModelSwitcherEntry,
        isSelected: Bool,
        fitVerdict: ModelSwitcherFitVerdict?,
        capabilityGlyphs: [ModelSwitcherCapabilityGlyph],
        isAvailable: Bool,
        unavailableReason: String?,
        downloadStatus: DownloadStatus?,
        endpointFault: String?
    ) {
        self.entry = entry
        self.isSelected = isSelected
        self.fitVerdict = fitVerdict
        self.capabilityGlyphs = capabilityGlyphs
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
        self.downloadStatus = downloadStatus
        self.endpointFault = endpointFault
    }
}

/// Builds the unified switcher row list.
///
/// Pure, data-only presentation-layer merge over ``ModelInfo`` +
/// ``APIEndpointRecord`` — the mutual-exclusion selection model already lives
/// on `ModelRegistry`/`ChatViewModel` (#1312) and is untouched here; this
/// type only decides what one combined list looks like.
public enum ModelSwitcher {

    /// - Parameters:
    ///   - models: ``ModelRegistry/availableModels``.
    ///   - endpoints: The host's configured cloud endpoints
    ///     (`EndpointStore.fetchEndpoints()`).
    ///   - selectedModelID: `ModelRegistry.selectedModel?.id`.
    ///   - selectedEndpointID: The active cloud endpoint's id, when one is
    ///     loaded.
    ///   - physicalMemoryBytes: Device RAM, for the fit-dot estimate
    ///     (``ModelLoadPlan/canRunModel(sizeBytes:physicalMemoryBytes:)``).
    ///   - compatibility: Per-``ModelType`` backend-availability query —
    ///     typically `FrameworkCapabilityService.compatibility(for:)`.
    ///   - downloadStatus: Inline download progress for a model not yet on
    ///     disk. Defaults to "no download in flight."
    ///   - endpointFault: A faulted endpoint's error message, when known.
    ///     Defaults to "no fault."
    public static func rows(
        models: [ModelInfo],
        endpoints: [APIEndpointRecord],
        selectedModelID: UUID?,
        selectedEndpointID: UUID?,
        physicalMemoryBytes: UInt64,
        compatibility: (ModelType) -> ModelCompatibilityResult,
        downloadStatus: (ModelInfo) -> DownloadStatus? = { _ in nil },
        endpointFault: (APIEndpointRecord) -> String? = { _ in nil }
    ) -> [ModelSwitcherRow] {
        let modelRows = models.map { model -> ModelSwitcherRow in
            let compat = compatibility(model.modelType)

            var glyphs: [ModelSwitcherCapabilityGlyph] = []
            if model.supportsReasoning { glyphs.append(.reasoning) }
            if model.toolCallClaim.toolsExpressible { glyphs.append(.tools) }
            if model.mmprojURL != nil { glyphs.append(.vision) }

            let fit: ModelSwitcherFitVerdict
            if model.modelType == .foundation {
                // System-managed — always resident, always "good" (mirrors
                // ModelLoadPlan.systemManaged's always-.allow verdict).
                fit = .good
            } else if model.fileSize == 0 {
                fit = .unknown
            } else if ModelLoadPlan.canRunModel(sizeBytes: model.fileSize, physicalMemoryBytes: physicalMemoryBytes) {
                fit = .good
            } else if ModelLoadPlan.canRunModel(sizeBytes: model.fileSize * 80 / 100, physicalMemoryBytes: physicalMemoryBytes) {
                fit = .warn
            } else {
                fit = .poor
            }

            return ModelSwitcherRow(
                entry: .model(model),
                isSelected: selectedModelID != nil && selectedModelID == model.id,
                fitVerdict: fit,
                capabilityGlyphs: glyphs,
                isAvailable: compat.isSupported,
                unavailableReason: compat.unavailableReason,
                downloadStatus: downloadStatus(model),
                endpointFault: nil
            )
        }

        let endpointRows = endpoints.map { endpoint -> ModelSwitcherRow in
            let fault = endpointFault(endpoint)
            return ModelSwitcherRow(
                entry: .endpoint(endpoint),
                isSelected: selectedEndpointID != nil && selectedEndpointID == endpoint.id,
                // Spec §5 rule 1: cloud rows render the accent tint, not a
                // fit dot — `nil` signals "no fit dot" to the row view.
                fitVerdict: nil,
                capabilityGlyphs: [],
                isAvailable: fault == nil,
                unavailableReason: fault,
                downloadStatus: nil,
                endpointFault: fault
            )
        }

        return modelRows + endpointRows
    }
}
