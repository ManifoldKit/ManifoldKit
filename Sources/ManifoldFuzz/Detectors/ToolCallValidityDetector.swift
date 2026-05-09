import Foundation
import ManifoldInference

/// Inspired by #627 — tool-call correctness is the most fragile piece of any
/// real integration. Targeted unit tests cover known cases; this detector catches
/// drift that nobody thought to test.
///
/// Five sub-checks against any `RunRecord` whose tool-call list is non-empty:
///
/// - `malformed-json-args` — every `ToolCall.arguments` parses as JSON.
/// - `schema-violation` — every `ToolCall.arguments` validates against the
///   corresponding `ToolDefinition.parameters` (reuses `JSONSchemaValidator`).
/// - `id-reuse` — no `ToolCall.id` appears twice in a single conversation.
/// - `orphan-result` — every `ToolResult.callId` references a preceding
///   `ToolCall.id`.
/// - `toolchoice-violation` — `toolChoice: .required` produced ≥1 call;
///   `.none` produced zero; `.tool(name:)` produced only that name.
///
/// Severity policy:
///
/// - `id-reuse` and `orphan-result` ship at `.confirmed`. Both are deterministic
///   transcript invariants — duplicate call IDs and results-for-unknown-calls
///   are zero-FP-by-construction (any honest backend respects them) so they
///   need no calibration corpus to graduate.
/// - `malformed-json-args`, `schema-violation`, and `toolchoice-violation`
///   ship at `.flaky` pending calibration corpus work tracked under #488 —
///   model decoding ambiguity and toolchoice-prompt drift can produce
///   defensible-but-noisy positives until the corpus settles FP < 2%.
public struct ToolCallValidityDetector: Detector {
    public let id = "tool-call-validity"
    public let humanName = "Tool-call invariant violations"
    public let inspiredBy = "#627 — tool-call correctness fuzz coverage"

    private let validator: JSONSchemaValidator

    public init(validator: JSONSchemaValidator = JSONSchemaValidator()) {
        self.validator = validator
    }

    public func inspect(_ r: RunRecord) -> [Finding] {
        // The toolchoice-violation sub-check fires even on zero tool calls: the
        // `.required` constraint produces a finding precisely when the call list
        // is empty. So inspect runs whenever a tool config was set, not only
        // when calls were emitted.
        if r.toolCalls.isEmpty && r.config.toolChoice == nil {
            return []
        }

        var findings: [Finding] = []

        // Index definitions by name so schema validation is O(calls) rather
        // than O(calls × defs). Replayed or hand-edited records can carry
        // duplicate names; build the lookup non-trappingly and keep the first
        // definition on collision so the detector can never crash a fuzz run.
        let definitionsByName: [String: ToolDefinition] = Dictionary(
            r.toolDefinitions.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var seenIds: Set<String> = []
        for call in r.toolCalls {
            if !isValidJSONObject(call.arguments) {
                findings.append(.init(
                    detectorId: id,
                    subCheck: "malformed-json-args",
                    severity: .flaky,
                    trigger: "\(call.toolName): \(String(call.arguments.prefix(120)))",
                    modelId: r.model.id
                ))
            } else if let def = definitionsByName[call.toolName] {
                if let failure = validator.validate(arguments: call.arguments, against: def.parameters) {
                    findings.append(.init(
                        detectorId: id,
                        subCheck: "schema-violation",
                        severity: .flaky,
                        trigger: "\(call.toolName): \(failure.modelReadableMessage)",
                        modelId: r.model.id
                    ))
                }
            }

            if seenIds.contains(call.id) {
                // Zero-FP-by-construction: a single conversation can never
                // legitimately reuse a call ID. .confirmed.
                findings.append(.init(
                    detectorId: id,
                    subCheck: "id-reuse",
                    severity: .confirmed,
                    trigger: "duplicate id \(call.id) for \(call.toolName)",
                    modelId: r.model.id
                ))
            }
            seenIds.insert(call.id)
        }

        let callIds = Set(r.toolCalls.map(\.id))
        for result in r.toolResults where !callIds.contains(result.callId) {
            // Zero-FP-by-construction: a result whose callId references no
            // preceding call is a recorder/orchestrator bug, not a model
            // judgement call. .confirmed.
            findings.append(.init(
                detectorId: id,
                subCheck: "orphan-result",
                severity: .confirmed,
                trigger: "result for unknown call \(result.callId)",
                modelId: r.model.id
            ))
        }

        if let choice = r.config.toolChoice, let violation = toolChoiceViolation(choice: choice, calls: r.toolCalls) {
            findings.append(.init(
                detectorId: id,
                subCheck: "toolchoice-violation",
                severity: .flaky,
                trigger: violation,
                modelId: r.model.id
            ))
        }

        return findings
    }

    private func isValidJSONObject(_ raw: String) -> Bool {
        guard let data = raw.data(using: .utf8) else { return false }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return true
        } catch {
            return false
        }
    }

    private func toolChoiceViolation(choice: String, calls: [ToolCall]) -> String? {
        if choice == "required" && calls.isEmpty {
            return "toolChoice=required produced zero calls"
        }
        if choice == "none" && !calls.isEmpty {
            let names = calls.map(\.toolName).joined(separator: ",")
            return "toolChoice=none produced calls: \(names)"
        }
        if choice.hasPrefix("tool:") {
            let required = String(choice.dropFirst("tool:".count))
            // Forced-tool with zero calls is a violation: a backend that
            // ignores the forced selection would otherwise look clean to
            // this sub-check.
            if calls.isEmpty {
                return "toolChoice=tool(\(required)) produced zero calls"
            }
            let mismatched = calls.filter { $0.toolName != required }
            if !mismatched.isEmpty {
                let names = mismatched.map(\.toolName).joined(separator: ",")
                return "toolChoice=tool(\(required)) produced unexpected calls: \(names)"
            }
        }
        return nil
    }
}

/// Encodes a `ToolChoice` as the string form persisted on `ConfigSnapshot`.
/// Public so `FuzzRunner` and CLI tooling can write it without re-implementing
/// the mapping.
public func encodeToolChoice(_ choice: ToolChoice) -> String {
    switch choice {
    case .auto: return "auto"
    case .none: return "none"
    case .required: return "required"
    case .tool(let name): return "tool:\(name)"
    }
}
