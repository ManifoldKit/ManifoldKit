import Foundation
import Observation

/// Manages global default settings persisted via UserDefaults.
///
/// Per-session overrides live in `ChatSession`; when a session's override is
/// `nil`, the view model falls back to these global defaults.
@Observable
public final class SettingsService: @unchecked Sendable {

    public static let shared = SettingsService()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Generation Defaults

    public var globalTemperature: Float? {
        get { defaults.object(forKey: "globalTemperature") as? Float }
        set {
            if let newValue { defaults.set(newValue, forKey: "globalTemperature") }
            else { defaults.removeObject(forKey: "globalTemperature") }
        }
    }

    public var globalTopP: Float? {
        get { defaults.object(forKey: "globalTopP") as? Float }
        set {
            if let newValue { defaults.set(newValue, forKey: "globalTopP") }
            else { defaults.removeObject(forKey: "globalTopP") }
        }
    }

    public var globalRepeatPenalty: Float? {
        get { defaults.object(forKey: "globalRepeatPenalty") as? Float }
        set {
            if let newValue { defaults.set(newValue, forKey: "globalRepeatPenalty") }
            else { defaults.removeObject(forKey: "globalRepeatPenalty") }
        }
    }

    public var globalPromptTemplate: PromptTemplate? {
        get {
            guard let raw = defaults.string(forKey: "globalPromptTemplate") else { return nil }
            return PromptTemplate(rawValue: raw)
        }
        set { defaults.set(newValue?.rawValue, forKey: "globalPromptTemplate") }
    }

    // MARK: - Appearance

    public var appearanceMode: AppearanceMode {
        get {
            guard let raw = defaults.string(forKey: "appearanceMode") else { return .system }
            return AppearanceMode(rawValue: raw) ?? .system
        }
        set { defaults.set(newValue.rawValue, forKey: "appearanceMode") }
    }

    // MARK: - Resolution Helpers

    /// Returns the effective temperature, using session override if available.
    public func effectiveTemperature(session: ChatSessionRecord?) -> Float {
        session?.temperature ?? globalTemperature ?? 0.7
    }

    public func effectiveTopP(session: ChatSessionRecord?) -> Float {
        session?.topP ?? globalTopP ?? 0.9
    }

    public func effectiveRepeatPenalty(session: ChatSessionRecord?) -> Float {
        session?.repeatPenalty ?? globalRepeatPenalty ?? 1.1
    }
}

/// Controls the app's color scheme preference.
public enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    public var id: String { rawValue }
}
