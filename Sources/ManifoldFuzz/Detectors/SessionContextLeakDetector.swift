import Foundation

/// Fires when a system prompt (or first user message) from one session
/// appears verbatim inside the assistant output of another session. That is
/// a session-context-leak: the service mixed inputs across ``sessionID``
/// boundaries, breaking the contract that ``InferenceService/enqueue``
/// scopes history per session.
///
/// The detector inspects a collection of ``SessionCapture`` instances — each
/// carries its own `sessionID`. A match is only flagged when the leaking
/// string is long enough (default 16 chars) that accidental overlap with a
/// common greeting is implausible. That threshold is what keeps the
/// adversarial boilerplate-greeting case silent.
public struct SessionContextLeakDetector: SessionDetector {
    public let id = "session-context-leak"
    public let humanName = "Session context leak"
    public let inspiredBy = "generic isolation bug"

    /// Minimum length for a shared substring to count as a leak.
    public let minLeakChars: Int

    public init(minLeakChars: Int = 16) {
        self.minLeakChars = minLeakChars
    }

    public func inspect(_ captures: [SessionCapture]) -> [Finding] {
        guard captures.count >= 2 else { return [] }

        // Pre-extract each session's secret-ish strings (system prompt + its
        // own first user message) and its concatenated assistant output so
        // the pairwise loop stays O(N²) in session count, not in message
        // count.
        struct SessionProbe {
            let capture: SessionCapture
            let secrets: [String]
            let assistantOutput: String
        }

        var probes: [SessionProbe] = []
        for capture in captures {
            var secrets: [String] = []
            if let sp = capture.script.systemPrompt,
               !sp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                secrets.append(sp)
            }
            if let firstUser = firstUserText(capture.script) {
                secrets.append(firstUser)
            }
            let output = capture.turnRecords.map(\.raw).joined(separator: "\n")
            probes.append(.init(capture: capture, secrets: secrets, assistantOutput: output))
        }

        var findings: [Finding] = []
        for (i, a) in probes.enumerated() {
            for (j, b) in probes.enumerated() where i != j {
                for secret in a.secrets {
                    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.count >= minLeakChars else { continue }
                    if b.assistantOutput.contains(trimmed) {
                        findings.append(.init(
                            detectorId: id,
                            subCheck: "system-prompt-leak",
                            severity: .flaky,
                            trigger: "session '\(a.capture.script.sessionLabel ?? a.capture.script.id)' secret '\(trimmed.prefix(60))' appeared in session '\(b.capture.script.sessionLabel ?? b.capture.script.id)'",
                            modelId: b.capture.turnRecords.first?.model.id ?? "unknown"
                        ))
                    }
                }
            }
        }
        return findings
    }

    private func firstUserText(_ script: SessionScript) -> String? {
        for step in script.steps {
            if case .send(let text) = step { return text }
        }
        return nil
    }
}
