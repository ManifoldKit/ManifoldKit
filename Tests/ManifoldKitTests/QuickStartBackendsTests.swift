// QuickStartBackendsTests.swift
//
// Exercises the v0.48 consumer-path APIs (#1749):
//   - `quickStart(backends:)` registrar injection, and its ordering contract
//     (injected registrars are visible to the seed and the selection policy).
//   - Runtime gating of the starter seed (no compile-time trait reflection).
//   - The selection policy's compatibility filter (on-disk models with no
//     registered backend must not be auto-selected).
//   - The backend-availability diagnostic decision table (fail-fast guard +
//     cloud-only-without-endpoint warning).
//
// These are integration tests: they drive the real `_quickStart` assembly
// against in-memory SwiftData containers, with `MockInferenceBackend`
// (ManifoldTestSupport) standing in for a runtime-registered family backend —
// exactly the shape a manifold-llama / manifold-mlx companion registrar has.

import XCTest
import Foundation
import SwiftData
import ManifoldInference
import ManifoldPersistenceSwiftData
import ManifoldTestSupport
@testable import ManifoldKit

// MARK: - Mock companion registrar

/// Stand-in for a companion package's registrar (e.g. `LlamaBackends` from
/// manifold-llama): registers a GGUF-capable backend with the service. The
/// shape mirrors the real family registrars — factory + declareSupport.
enum MockGGUFBackends: BackendRegistrar {
    @MainActor
    static func register(with service: InferenceService) {
        service.registerBackendFactory { modelType in
            modelType == .gguf ? MockInferenceBackend() : nil
        }
        service.declareSupport(for: .gguf)
    }
}

@MainActor
final class QuickStartBackendsTests: XCTestCase {

    private var tempDir: URL = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickStartBackends-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
    }

    override func tearDownWithError() throws {
        do {
            try FileManager.default.removeItem(at: tempDir)
        } catch {
            // Best-effort cleanup of a per-test scratch dir; nothing to assert.
        }
        try super.tearDownWithError()
    }

    /// Returns true when the *compiled-in* default registrars already provide
    /// a GGUF backend (Llama-trait builds). Negative gating cases are not
    /// arrangeable in those builds because `_quickStart` always folds the
    /// defaults first — skip honestly instead of asserting a vacuous pass.
    private var buildHasCompiledInGGUFBackend: Bool {
        let probe = InferenceService()
        for registrar in ManifoldKit.defaultBackendRegistrars {
            registrar.register(with: probe)
        }
        return probe.registeredBackendSnapshot().supportsGGUF
    }

    private func makeGGUFModelInfo(name: String = "test.gguf") -> ModelInfo {
        ModelInfo(
            id: UUID(),
            name: "Test GGUF",
            fileName: name,
            url: tempDir.appendingPathComponent(name),
            fileSize: 500_000,
            modelType: .gguf
        )
    }

    // MARK: - quickStart(backends:) ordering

    /// The whole point of registrar injection: backends passed to
    /// `quickStart(backends:)` must be registered *before* the selection
    /// policy runs, so the policy's compatibility queries see them.
    /// (Registering after quickStart returns is too late — review blocker.)
    func test_quickStartBackends_injectedRegistrarVisibleAtSelectionPolicyTime() async throws {
        // Recorded inside the policy closure, i.e. at the exact pipeline stage
        // whose ordering this test pins.
        var ggufSupportedAtPolicyTime: Bool?

        _ = try await ManifoldKit._quickStart(
            configuration: .default,
            backends: [MockGGUFBackends.self],
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            selectionPolicy: { registry in
                ggufSupportedAtPolicyTime = registry.compatibility(for: .gguf).isSupported
                return nil
            }
        )

        XCTAssertEqual(ggufSupportedAtPolicyTime, true,
            "A registrar injected via quickStart(backends:) must be registered before the selection policy runs (#1749)")
    }

    /// End-to-end: with an injected GGUF backend, the *default* policy selects
    /// an on-disk GGUF model — the post-split consumer happy path.
    func test_quickStartBackends_defaultPolicy_selectsModelLoadableByInjectedBackend() async throws {
        let localModel = makeGGUFModelInfo()

        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            backends: [MockGGUFBackends.self],
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            selectionPolicy: { registry in
                // Deterministic regardless of test-host OS / Apple Intelligence.
                registry.foundationModelProvider = { false }
                registry.availableModels = [localModel]
                return await ManifoldKit.defaultSelectionPolicy(registry)
            }
        )

        XCTAssertEqual(result.viewModel.modelRegistry.selectedModel?.id, localModel.id,
            "Default policy must select a model loadable by a runtime-injected backend")
    }

    // MARK: - Seed runtime gating

    /// The GGUF starter seed must run when a GGUF-capable backend is
    /// registered at runtime via `quickStart(backends:)` — the compile-time
    /// trait check it replaced could never see this case.
    func test_seed_runs_whenGGUFBackendInjectedAtRuntime() async throws {
        let manager = MockDownloadManager()
        // Pre-seed a completed DownloadState so the poll loop exits
        // immediately — reaching startDownload at all is the property under
        // test. (startDownloadError can't be used here: the mock throws
        // before recording into startedModels.)
        let seed = QuickStartSeed.recommendedSmallModel()
        let model = DownloadableModel(
            repoID: seed.repoID,
            fileName: seed.fileName,
            displayName: seed.displayName,
            modelType: seed.modelType,
            sizeBytes: seed.sizeBytes
        )
        let completedState = DownloadState(model: model)
        completedState.markCompleted(localURL: tempDir.appendingPathComponent(seed.fileName))
        manager.activeDownloads[model.id] = completedState

        _ = try await ManifoldKit._quickStart(
            configuration: .default,
            backends: [MockGGUFBackends.self],
            seed: seed,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            downloadManagerOverride: manager,
            foundationAvailableOverride: false,
            // Isolated empty scratch dir: the "model already on disk" skip
            // gate must not fire from ambient models on the test host.
            storageServiceOverride: ModelStorageService(
                baseDirectory: tempDir,
                includeUserDocumentsFallback: false
            ),
            selectionPolicy: { _ in nil }
        )

        XCTAssertFalse(manager.startedModels.isEmpty,
            "Seed must attempt the download when a runtime-injected backend can load .gguf (#1735 re-based on runtime registration)")
    }

    /// Without any GGUF-capable backend registered, the seed must skip —
    /// downloading ~484 MB nothing can load is the silent-failure trap this
    /// gate exists to close.
    func test_seed_skips_whenNoRegisteredBackendCanLoadGGUF() async throws {
        try XCTSkipIf(buildHasCompiledInGGUFBackend,
            "Compiled-in GGUF backend present (Llama trait) — the no-GGUF-backend case is not arrangeable in this build")

        let manager = MockDownloadManager()

        _ = try await ManifoldKit._quickStart(
            configuration: .default,
            seed: .recommendedSmallModel(),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            downloadManagerOverride: manager,
            foundationAvailableOverride: false,
            storageServiceOverride: ModelStorageService(
                baseDirectory: tempDir,
                includeUserDocumentsFallback: false
            ),
            selectionPolicy: { _ in nil }
        )

        XCTAssertTrue(manager.startedModels.isEmpty,
            "Seed must skip when no registered backend can load .gguf — a download nothing can load is dead weight")
    }

    // MARK: - Selection compatibility filter

    /// An on-disk model whose type has NO registered backend must not be
    /// auto-selected: the model would appear selected, the app would compile
    /// and launch clean, and the first send would fail with a confusing load
    /// error (worst silent break of the companion split).
    func test_defaultPolicy_skipsModel_withNoRegisteredBackend() async throws {
        // Fresh service with nothing registered — deterministic in every
        // trait combination, unlike driving _quickStart (which always folds
        // the compiled-in defaults).
        let service = InferenceService()
        let registry = ModelRegistry(
            inferenceService: service,
            modelStorage: ModelStorageService(
                baseDirectory: tempDir,
                includeUserDocumentsFallback: false
            )
        )
        registry.foundationModelProvider = { false }
        registry.availableModels = [makeGGUFModelInfo()]

        let chosen = await ManifoldKit.defaultSelectionPolicy(registry)

        XCTAssertNil(chosen,
            "defaultSelectionPolicy must not auto-select a model no registered backend can load")
    }

    /// Counterpart: the same registry picks the model once a capable backend
    /// registers — proving the nil above comes from the compatibility filter,
    /// not from some other property of the setup.
    func test_defaultPolicy_selectsModel_onceBackendRegisters() async throws {
        let service = InferenceService()
        let registry = ModelRegistry(
            inferenceService: service,
            modelStorage: ModelStorageService(
                baseDirectory: tempDir,
                includeUserDocumentsFallback: false
            )
        )
        registry.foundationModelProvider = { false }
        let model = makeGGUFModelInfo()
        registry.availableModels = [model]

        MockGGUFBackends.register(with: service)
        let chosen = await ManifoldKit.defaultSelectionPolicy(registry)

        XCTAssertEqual(chosen?.id, model.id,
            "defaultSelectionPolicy must select the model once a capable backend is registered")
    }

    // MARK: - Backend-availability diagnostic

    /// Decision table for the runtime guard that replaced the trait-based
    /// "registered count > 0" check. Pure-function tests so every case is
    /// reachable in every build (driving _quickStart can't produce an empty
    /// snapshot in Foundation-capable builds).
    func test_backendAvailabilityDiagnostic_decisionTable() {
        // Nothing registered at all → fail fast.
        XCTAssertEqual(
            ManifoldKit.backendAvailabilityDiagnostic(
                snapshot: EnabledBackends(),
                configuredEndpointCount: 0
            ),
            .noBackends,
            "Empty registration must keep the noBackendsRegistered fail-fast reachable"
        )

        // Cloud-only, no endpoint configured → actionable warning.
        let cloudOnly = EnabledBackends(localModelTypes: [], cloudProviders: [.ollama])
        let diagnostic = ManifoldKit.backendAvailabilityDiagnostic(
            snapshot: cloudOnly,
            configuredEndpointCount: 0
        )
        guard case .cloudOnlyWithoutEndpoint(let message) = diagnostic else {
            XCTFail("Cloud-only + zero endpoints must produce the cloudOnlyWithoutEndpoint warning, got \(String(describing: diagnostic))")
            return
        }
        // The message must name the companion packages and both remediation
        // paths — that wording is the deliverable (plan §8 risk 2).
        XCTAssertTrue(message.contains("manifold-llama"), "Warning must name manifold-llama")
        XCTAssertTrue(message.contains("manifold-mlx"), "Warning must name manifold-mlx")
        XCTAssertTrue(message.contains("quickStart(backends:"), "Warning must point at the registrar-injection API")
        XCTAssertTrue(message.contains("APIEndpointRecord"), "Warning must point at the cloud-endpoint remediation")

        // Cloud-only with a configured endpoint → healthy, no diagnostic.
        XCTAssertNil(
            ManifoldKit.backendAvailabilityDiagnostic(
                snapshot: cloudOnly,
                configuredEndpointCount: 1
            ),
            "A configured endpoint makes a cloud-only service usable — no diagnostic"
        )

        // Any local backend → healthy regardless of endpoints.
        XCTAssertNil(
            ManifoldKit.backendAvailabilityDiagnostic(
                snapshot: EnabledBackends(localModelTypes: [.gguf], cloudProviders: []),
                configuredEndpointCount: 0
            ),
            "Local inference available — no diagnostic"
        )
    }

    /// #2157: when the only registrar(s) passed to `quickStart(backends:)`
    /// are `FoundationBackends`, and the host is below the Apple Intelligence
    /// OS floor, the diagnostic must pin the cause to the OS gate rather than
    /// falling back to the generic "nothing registered" message — the
    /// registrar DID run, it just declared no supported model type.
    func test_backendAvailabilityDiagnostic_osGatedFoundationOnly_producesTargetedDiagnostic() {
        let diagnostic = ManifoldKit.backendAvailabilityDiagnostic(
            snapshot: EnabledBackends(),
            configuredEndpointCount: 0,
            registrars: [FoundationBackends.self],
            foundationModelsOSAvailable: false
        )
        guard case .noBackendsOSGated(let reason) = diagnostic else {
            XCTFail("Expected .noBackendsOSGated when FoundationBackends is the only registrar and the OS is below the floor, got \(String(describing: diagnostic))")
            return
        }
        XCTAssertTrue(reason.contains("Apple Intelligence") || reason.contains("iOS 26") || reason.contains("macOS 26"),
            "Reason must name the OS floor so the host knows exactly why: \(reason)")
    }

    /// Counterpart: the same empty snapshot with NO `FoundationBackends` in
    /// the registrar list must still fall back to the generic diagnostic —
    /// the OS-gate detection is deliberately narrow (it can only introspect
    /// the one registrar it knows the gating shape of), not a catch-all for
    /// "empty snapshot with any registrar present".
    func test_backendAvailabilityDiagnostic_osGateDetection_scopedToFoundationBackendsOnly() {
        let diagnostic = ManifoldKit.backendAvailabilityDiagnostic(
            snapshot: EnabledBackends(),
            configuredEndpointCount: 0,
            registrars: [MockGGUFBackends.self],
            foundationModelsOSAvailable: false
        )
        XCTAssertEqual(diagnostic, .noBackends,
            "A non-Foundation registrar producing an empty snapshot must stay the generic .noBackends diagnostic")
    }

    /// Counterpart: `FoundationBackends` present but the OS floor IS met
    /// must not misfire the OS-gated diagnostic (an empty snapshot in that
    /// case indicates a different, non-OS problem — e.g. Apple Intelligence
    /// disabled by the user — which the generic message already covers).
    func test_backendAvailabilityDiagnostic_foundationBackendsPresent_osAvailable_staysGeneric() {
        let diagnostic = ManifoldKit.backendAvailabilityDiagnostic(
            snapshot: EnabledBackends(),
            configuredEndpointCount: 0,
            registrars: [FoundationBackends.self],
            foundationModelsOSAvailable: true
        )
        XCTAssertEqual(diagnostic, .noBackends,
            "FoundationBackends registered with the OS floor met must not report an OS gate that isn't the cause")
    }

    /// End-to-end: `_quickStart` with only `FoundationBackends` registered on
    /// a genuinely pre-floor OS must still throw
    /// `ManifoldKitError.noBackendsRegistered` (there is no dedicated public
    /// case for the OS-gate cause — see that case's doc comment), but the
    /// error's diagnostic MESSAGE must name the OS floor + a concrete
    /// remediation rather than only the generic "call register(with:)" text
    /// — exercised through the real assembly path (not just the pure
    /// decision table above).
    ///
    /// `FoundationBackends.register(with:)` gates `declareSupport(for:)`
    /// behind the REAL `#available(iOS 26, macOS 26, *)` check, not the
    /// `foundationAvailableOverride` test seam (that seam only feeds the
    /// downstream diagnostic/seed logic) — so this negative case is only
    /// arrangeable on a build whose host OS is itself below the floor.
    /// Mirrors `buildHasCompiledInGGUFBackend`'s honest-skip precedent above
    /// rather than asserting a vacuous pass on a capable host.
    func test_quickStart_osGatedFoundationOnly_throwsTargetedError() async throws {
        try XCTSkipIf(ManifoldKit.foundationModelsOSAvailable,
            "Host OS meets the Apple Intelligence floor — the OS-gated-registration case is not arrangeable on this build")

        do {
            _ = try await ManifoldKit._quickStart(
                configuration: .default,
                backends: [FoundationBackends.self],
                includeDefaultBackends: false,
                makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
                selectionPolicy: { _ in nil }
            )
            XCTFail("_quickStart must throw when only an OS-gated backend is registered and the OS gate is closed")
        } catch let error as ManifoldKitError {
            guard case .noBackendsRegistered = error else {
                XCTFail("Expected ManifoldKitError.noBackendsRegistered, got \(error)")
                return
            }
            let description = try XCTUnwrap(error.errorDescription, "noBackendsRegistered must supply errorDescription")
            XCTAssertTrue(
                description.contains("Apple Intelligence") || description.contains("iOS 26") || description.contains("macOS 26"),
                "Diagnostic message must name the OS floor so the host knows exactly why: \(description)"
            )
            XCTAssertTrue(
                description.contains("APIEndpointRecord") || description.contains("cloud endpoint"),
                "Diagnostic message must offer a concrete remediation: \(description)"
            )
            XCTAssertFalse(error.isRetryable, "An OS gate is not resolved by retrying")
        }
    }

    // MARK: - Local-only / replace-mode (includeDefaultBackends: false)

    /// The privacy guarantee: with `includeDefaultBackends: false`, the cloud
    /// families (Ollama + SaaS) must NOT reach the service — only the
    /// caller-named registrars are wired. Asserted on the live registration
    /// snapshot, not by inspection of the registration loop.
    func test_includeDefaultBackendsFalse_registersNoCloudBackends() async throws {
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            backends: [MockGGUFBackends.self],
            includeDefaultBackends: false,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            selectionPolicy: { _ in nil }
        )

        let snapshot = result.bootstrap.inferenceService.registeredBackendSnapshot()
        XCTAssertTrue(snapshot.cloudProviders.isEmpty,
            "includeDefaultBackends: false must register zero cloud providers — got \(snapshot.cloudProviders)")
        XCTAssertFalse(snapshot.supportsCloudInference,
            "A local-only runtime must report no cloud inference capability")
        // The caller's own backend must still be wired (replace, not erase).
        XCTAssertTrue(snapshot.supportsGGUF,
            "The caller-supplied registrar must still register under includeDefaultBackends: false")
    }

    /// Counterpart proving the assertion above is meaningful: the DEFAULT path
    /// (includeDefaultBackends defaults to true) DOES register cloud providers,
    /// so existing-caller behaviour is provably unchanged.
    func test_defaultPath_registersCloudBackends_behaviourUnchanged() async throws {
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            backends: [MockGGUFBackends.self],
            // includeDefaultBackends defaults to true — the existing behaviour.
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            selectionPolicy: { _ in nil }
        )

        let snapshot = result.bootstrap.inferenceService.registeredBackendSnapshot()
        XCTAssertTrue(snapshot.supportsCloudInference,
            "The default path must keep registering the compiled-in cloud families (unchanged behaviour)")
        XCTAssertFalse(snapshot.cloudProviders.isEmpty,
            "The default path must register at least one cloud provider — got none")
    }

    /// `localOnly(backends:)` is the public convenience: it must register the
    /// caller's on-device backend without any cloud provider.
    func test_localOnly_registersNoCloudBackends() async throws {
        // Drive the same assembly localOnly uses, with the mock GGUF backend
        // standing in for a companion local registrar. (We exercise the
        // mechanism directly rather than calling localOnly() so the on-device
        // local backend is present regardless of the test host's OS / Apple
        // Intelligence availability.)
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            backends: [MockGGUFBackends.self],
            includeDefaultBackends: false,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            selectionPolicy: { _ in nil }
        )

        let snapshot = result.bootstrap.inferenceService.registeredBackendSnapshot()
        XCTAssertFalse(snapshot.supportsCloudInference,
            "localOnly must never register a cloud backend")
        XCTAssertTrue(snapshot.supportsLocalInference,
            "localOnly with a local registrar must support local inference")
    }

    /// The guard stays wired through the real assembly path: an injected
    /// local backend must produce a successful, fully-wired launch (and the
    /// healthy path must not throw noBackendsRegistered).
    func test_quickStartBackends_injectedLocalBackend_launchesClean() async throws {
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            backends: [MockGGUFBackends.self],
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            selectionPolicy: { _ in nil }
        )

        XCTAssertNotNil(result.viewModel.activeSession,
            "quickStart(backends:) must produce a usable chat surface")
        XCTAssertTrue(
            result.bootstrap.inferenceService.registeredBackendSnapshot().supportsGGUF,
            "Injected registrar's support must be visible on the bootstrap's service after quickStart returns"
        )
    }
}
