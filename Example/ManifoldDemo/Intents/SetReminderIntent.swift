import AppIntents
import Foundation

/// Demo intent surfaced through ``AppIntentToolExecutor`` so the model can
/// invoke it during a chat turn.
///
/// The intent doesn't actually wire into EventKit — it logs the request and
/// returns the formatted reminder text. The point is to demonstrate the
/// AppIntent → ToolExecutor bridge, not to ship a real reminder feature.
///
/// `Decodable` conformance is required by ``AppIntentToolExecutor`` because
/// AppIntents doesn't synthesise it for property-wrapper-shadowed storage.
@available(iOS 26, macOS 26, *)
public struct SetReminderIntent: AppIntent, Decodable {

    public static let title: LocalizedStringResource = "Set a reminder"

    public static let description = IntentDescription(
        "Records a reminder string with an optional time. Demo-only; nothing is persisted.",
        categoryName: "Productivity"
    )

    @Parameter(title: "Text", description: "What you want to be reminded about.")
    public var text: String

    @Parameter(title: "When", description: "Optional date/time for the reminder.")
    public var when: Date?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.text = try c.decode(String.self, forKey: .text)
        self.when = try c.decodeIfPresent(Date.self, forKey: .when)
    }

    private enum CodingKeys: String, CodingKey { case text, when }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let summary: String
        if let when {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            summary = "Reminder set for \(formatter.string(from: when)): \(text)"
        } else {
            summary = "Reminder noted: \(text)"
        }
        return .result(value: summary)
    }
}
