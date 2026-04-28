import Foundation

public struct SpeechTranscriptionUpdate: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

public enum VoiceAuthorizationStatus: Sendable, Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unsupportedLocale
    case microphoneDenied
}

public enum VoiceCaptureState: Equatable {
    case idle
    case requestingPermission
    case recording
    case processing
    case failed(String)
}

public enum VoiceError: LocalizedError, Equatable {
    case recognizerUnavailable
    case unsupportedLocale
    case speechRecognitionDenied
    case speechRecognitionRestricted
    case microphoneAccessDenied
    case simulatorUnsupported
    case setupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            "Speech recognition is unavailable right now."
        case .unsupportedLocale:
            "Speech recognition is unavailable for the current locale."
        case .speechRecognitionDenied:
            "Speech recognition permission is required for voice input."
        case .speechRecognitionRestricted:
            "Speech recognition is restricted on this device."
        case .microphoneAccessDenied:
            "Microphone access is required for voice input."
        case .simulatorUnsupported:
            "Voice capture is unavailable in the simulator."
        case .setupFailed(let message):
            "Voice capture could not start: \(message)"
        }
    }
}

public protocol SpeechTranscribing: AnyObject {
    @MainActor
    func requestAuthorization() async -> VoiceAuthorizationStatus

    @MainActor
    func startTranscribing(
        onUpdate: @escaping @MainActor (SpeechTranscriptionUpdate) -> Void
    ) async throws

    @MainActor
    func stopTranscribing() async throws -> String?

    @MainActor
    func cancelTranscribing()
}

public protocol SpeechSynthesizing: AnyObject {
    @MainActor
    func speak(_ text: String) async throws

    @MainActor
    func stopSpeaking()
}
