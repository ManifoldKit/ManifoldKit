import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Parity matrix: verifies that the ``ToolRegistry`` dispatch layer maps each
/// failure mode to the correct ``ToolResult/ErrorKind`` regardless of which
/// simulated backend flavor is exercised.
///
/// ## What this tests
///
/// ``ToolRegistry/dispatch(_:)`` is the single seam between the generation
/// loop and user-registered tools. Every cloud backend (OpenAI Chat, OpenAI
/// Responses, Ollama, Anthropic/Claude) and every local backend (MLX) returns
/// a ``ToolResult`` through this seam. The parity matrix here confirms that:
///
/// 1. All 9 ``ToolResult/ErrorKind`` cases surface correctly.
/// 2. Kinds that are synthesised by the registry (``unknownTool``,
///    ``invalidArguments``, ``cancelled``) are never altered by the executor.
/// 3. Kinds that are *returned* by the executor (all others) pass through
///    unchanged.
///
/// ## What this does NOT test
///
/// - Codable round-trips for ``ToolResult/ErrorKind`` — covered by
///   ``ToolResultErrorKindTests``.
/// - Detailed cancellation contract (propagation, leak-check, uncooperative
///   executor) — covered by ``ToolCancellationContractTests``.
///
/// ## Backend column semantics
///
/// ``ManifoldInference`` tests cannot import cloud-specific backend
/// implementations (those live in ``ManifoldBackends``). Each "backend" row
/// in the matrix is therefore a labelled mock executor that simulates the
/// result shape that backend produces at the ``ToolRegistry`` boundary. The
/// behavior under test is the registry's classification logic, not the
/// backend's wire-format parsing.
///
/// Foundation row is included (tool calling shipped in #713). Because the
/// matrix is mock-driven, the Foundation row needs no hardware or availability
/// gate.
@MainActor
final class ToolErrorClassificationParityTests: XCTestCase {

    // MARK: - Matrix definition

    /// One row of the parity matrix.
    ///
    /// `backend` and `fault` are purely documentary — they label the cell in
    /// error output so a failure points directly to the affected (backend, kind)
    /// pair. The `configure` closure wires the registry so that dispatching
    /// `matrixCallID` against `matrixToolName` produces `expectedKind`.
    private struct MatrixRow {
        /// Human-readable backend label (e.g. "openai-chat", "anthropic").
        let backend: String
        /// Human-readable fault description (e.g. "invalidArguments").
        let fault: String
        /// The ``ToolResult/ErrorKind`` expected in the dispatched result.
        let expectedKind: ToolResult.ErrorKind
        /// Wires the registry for this cell.
        ///
        /// Called immediately before dispatch. The closure registers an
        /// executor (or deliberately omits registration for `unknownTool`
        /// cells) and configures the ``ToolCall`` arguments string so the
        /// registry's parse path is exercised correctly.
        let configure: @MainActor (ToolRegistry) -> Void
        /// The ``ToolCall/arguments`` string the matrix row dispatches.
        ///
        /// Most rows use `"{}"` (valid empty-object JSON). `invalidArguments`
        /// rows use `"not-json"` so the registry's own parse path fires.
        /// `unknownTool` rows register nothing, so the value is irrelevant.
        let arguments: String

        init(
            backend: String,
            fault: String,
            expectedKind: ToolResult.ErrorKind,
            arguments: String = "{}",
            configure: @escaping @MainActor (ToolRegistry) -> Void
        ) {
            self.backend = backend
            self.fault = fault
            self.expectedKind = expectedKind
            self.arguments = arguments
            self.configure = configure
        }
    }

    // MARK: - Executor factory helpers

    /// Returns an executor whose `execute` returns a ``ToolResult`` with the
    /// given `errorKind`. Used for all executor-classified kinds (everything
    /// except the registry-synthesised ones: `unknownTool`, `invalidArguments`,
    /// `cancelled`).
    private static func returningExecutor(
        name: String,
        errorKind: ToolResult.ErrorKind?
    ) -> some ToolExecutor {
        ReturningKindExecutor(name: name, errorKind: errorKind)
    }

    // MARK: - Matrix

    /// Parity matrix: all 9 ``ToolResult/ErrorKind`` cases × the relevant
    /// backend flavors. Each row is independent — the registry is rebuilt per
    /// row in `runMatrix()`.
    ///
    /// Column rules:
    /// - `unknownTool` rows deliberately register NO executor so the registry
    ///   synthesises the kind.
    /// - `invalidArguments` rows supply `"not-json"` arguments so the registry
    ///   parse path fires (rather than an executor returning the kind, which
    ///   is also valid but is already covered by the other rows for
    ///   `invalidArguments`).
    /// - `cancelled` rows use an always-throwing `CancellationError` executor;
    ///   the full cancellation contract (propagation, user-stop, leak-check)
    ///   is covered in ``ToolCancellationContractTests``.
    /// - All other rows return a ``ToolResult`` with the target `errorKind`
    ///   directly — the registry must not alter it.
    ///
    /// Sabotage: change `.invalidArguments` to `.permanent` in the openai-chat
    /// row and the `invalidArguments` assertion flips.
    ///
    /// Sabotage: remove the `guard let executor` branch in
    /// ``ToolRegistry/dispatch(_:)`` and the `unknownTool` row stops failing
    /// the XCTAssertEqual check.
    ///
    /// Sabotage: replace `errorKind: raw.errorKind` with `errorKind: .permanent`
    /// in the registry's happy-path stamping block and all executor-classified
    /// rows (permissionDenied, notFound, timeout, rateLimited, transient,
    /// permanent) break simultaneously.
    private static let matrix: [MatrixRow] = {
        // Build the rows for every kind × every applicable backend.
        // Backends: openai-chat, openai-responses, ollama, anthropic, mlx,
        // foundation (tool calling shipped in #713; matrix is mock-driven so no
        // hardware/availability gate is needed).
        let backends = ["openai-chat", "openai-responses", "ollama", "anthropic", "mlx", "foundation"]

        var rows: [MatrixRow] = []

        // ── .invalidArguments ────────────────────────────────────────────────
        // Registry synthesises this when argument JSON is unparseable.
        // The executor is still registered so only the parse fails.
        for backend in backends {
            rows.append(MatrixRow(
                backend: backend,
                fault: "invalidArguments",
                expectedKind: .invalidArguments,
                arguments: "not-json",  // triggers parse failure in dispatch()
                configure: { registry in
                    // Register a no-op executor; it will never be reached
                    // because the parse step fires first.
                    registry.register(returningExecutor(name: "tool", errorKind: nil))
                }
            ))
        }

        // ── .unknownTool ─────────────────────────────────────────────────────
        // Registry synthesises this when no executor is registered for the name.
        for backend in backends {
            rows.append(MatrixRow(
                backend: backend,
                fault: "unknownTool",
                expectedKind: .unknownTool,
                configure: { _ in
                    // Deliberately register nothing so the lookup fails.
                }
            ))
        }

        // ── .cancelled ───────────────────────────────────────────────────────
        // Registry synthesises this when the executor throws `CancellationError`.
        // Detailed contract (user-stop propagation, leak check, uncooperative
        // executor) is covered in ToolCancellationContractTests.
        for backend in backends {
            rows.append(MatrixRow(
                backend: backend,
                fault: "cancelled",
                expectedKind: .cancelled,
                configure: { registry in
                    registry.register(CancellationThrowingExecutor(name: "tool"))
                }
            ))
        }

        // ── Executor-classified kinds ─────────────────────────────────────────
        // The executor returns a ToolResult with the target errorKind; the
        // registry must pass it through unchanged.
        let executorKinds: [ToolResult.ErrorKind] = [
            .permissionDenied,
            .notFound,
            .timeout,
            .rateLimited,
            .transient,
            .permanent,
        ]

        for kind in executorKinds {
            for backend in backends {
                rows.append(MatrixRow(
                    backend: backend,
                    fault: kind.rawValue,
                    expectedKind: kind,
                    configure: { registry in
                        registry.register(returningExecutor(name: "tool", errorKind: kind))
                    }
                ))
            }
        }

        return rows
    }()

    // MARK: - Test

    /// Drives every row in the matrix: configures a fresh registry, dispatches
    /// a call, and asserts `result.errorKind == row.expectedKind`.
    ///
    /// Backend labels in this matrix are simulated via mock executors —
    /// including "mlx" — so the entire matrix runs on every platform without
    /// hardware gating. The behavior under test is the registry's
    /// classification seam, not real backend code.
    ///
    /// The Foundation row is included here — tool calling shipped in #713 and
    /// the mock-driven matrix needs no hardware/availability gate.
    func test_parityMatrix_allErrorKinds_allBackends() async {
        for row in Self.matrix {
            let registry = ToolRegistry()
            // Disable the default 32 KB output-size guard so it never
            // interferes with the error-kind assertion. The matrix is testing
            // errorKind classification, not byte-budget enforcement.
            registry.outputPolicy = ToolOutputPolicy(maxBytes: .max, onOversize: .allow)
            // Disable the default schema validator so argument-content rows
            // aren't re-classified by validation before reaching the executor.
            registry.validator = nil

            row.configure(registry)

            let call = ToolCall(
                id: "matrix-\(row.backend)-\(row.fault)",
                toolName: "tool",
                arguments: row.arguments
            )
            let result = await registry.dispatch(call)

            XCTAssertEqual(
                result.errorKind,
                row.expectedKind,
                "[\(row.backend)/\(row.fault)] expected errorKind=\(row.expectedKind.rawValue), got \(result.errorKind.map(\.rawValue) ?? "<nil>")"
            )
            XCTAssertEqual(
                result.callId,
                call.id,
                "[\(row.backend)/\(row.fault)] callId must be stamped from the incoming ToolCall"
            )
        }
    }
}

// MARK: - Test executor helpers

/// Executor that always returns a ``ToolResult`` with the given `errorKind`.
///
/// Used by every matrix row that tests executor-classified error kinds
/// (`permissionDenied`, `notFound`, `timeout`, `rateLimited`, `transient`,
/// `permanent`) as well as the success case (`errorKind == nil`).
private struct ReturningKindExecutor: ToolExecutor, Sendable {
    let definition: ToolDefinition
    let errorKind: ToolResult.ErrorKind?

    init(name: String, errorKind: ToolResult.ErrorKind?) {
        self.definition = ToolDefinition(name: name, description: "test", parameters: .object([:]))
        self.errorKind = errorKind
    }

    func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        ToolResult(callId: "", content: "result for \(errorKind?.rawValue ?? "success")", errorKind: errorKind)
    }
}

/// Executor that throws ``CancellationError`` unconditionally.
///
/// Drives the `.cancelled` matrix rows. The registry catches
/// `CancellationError` and returns a ``ToolResult/ErrorKind/cancelled`` result.
///
/// The detailed cancellation contract — user-stop propagation, uncooperative
/// executor upgrade, bridged-handle leak check — is covered separately in
/// ``ToolCancellationContractTests``.
private struct CancellationThrowingExecutor: ToolExecutor, Sendable {
    let definition: ToolDefinition

    init(name: String) {
        self.definition = ToolDefinition(name: name, description: "throws cancellation", parameters: .object([:]))
    }

    func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        // Detailed cancellation contract covered in ToolCancellationContractTests.
        throw CancellationError()
    }
}
