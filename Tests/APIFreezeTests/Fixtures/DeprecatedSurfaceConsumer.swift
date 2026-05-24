import Foundation
import ManifoldRuntime

// MARK: - Deprecated API surface pins
//
// Kept in a dedicated file and behind an @available(*, deprecated) enum so
// the Swift compiler does not emit "X is deprecated" warnings from the
// non-deprecated host in PublicSurfaceConsumer.consumeAllSurfaces(). The
// compilation assertion is unchanged: if any of these types is removed or
// its init signature changes, this file fails to compile and CI fails.

/// @available(*, deprecated) shell whose sole purpose is to let Swift
/// suppress deprecation warnings on the call sites inside it. The type
/// is never instantiated; compilation is the assertion.
@available(*, deprecated)
enum DeprecatedSurfaceConsumer {

    // MARK: - ManifoldRuntime legacy input types (#1427)

    static func consumeDeprecatedRuntimeInputs() {
        let sessionID = UUID()

        // SendInput — full init signature freeze (all parameters explicit)
        let _: SendInput = SendInput(
            sessionID: sessionID,
            userText: "hi",
            attachments: [],
            systemPrompt: nil,
            temperature: 0.7,
            topP: 0.9,
            repeatPenalty: 1.1,
            maxOutputTokens: 2048,
            maxThinkingTokens: nil,
            streamingUpdateInterval: .milliseconds(33),
            streamingBatchCharacterLimit: 128,
            thinkingStreamingUpdateInterval: .milliseconds(33),
            thinkingStreamingBatchCharacterLimit: 128,
            loopDetectionEnabled: true
        )

        // SendInput — convenience init (defaulted parameters)
        let _: SendInput = SendInput(sessionID: sessionID, userText: "hi")

        // RegenerateInput
        let _: RegenerateInput = RegenerateInput(sessionID: sessionID)
    }
}
