import ManifoldInference
import Foundation

import AnyLanguageModel

enum AnyLanguageModelStreamBridge {
    static func makeEvents(
        from responseStream: LanguageModelSession.ResponseStream<String>
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var lastText = ""
                    for try await snapshot in responseStream {
                        let currentText = text(from: snapshot)
                        let delta = suffix(afterCommonPrefixBetween: lastText, and: currentText)
                        if !delta.isEmpty {
                            continuation.yield(.token(delta))
                        }
                        lastText = currentText
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func text(
        from snapshot: LanguageModelSession.ResponseStream<String>.Snapshot
    ) -> String {
        switch snapshot.rawContent.kind {
        case .string(let text):
            return text
        default:
            return String(describing: snapshot.content)
        }
    }

    private static func suffix(afterCommonPrefixBetween previous: String, and current: String) -> String {
        let previousChars = Array(previous)
        let currentChars = Array(current)
        var index = 0
        while index < previousChars.count && index < currentChars.count && previousChars[index] == currentChars[index] {
            index += 1
        }
        return index < currentChars.count ? String(currentChars[index...]) : ""
    }
}
