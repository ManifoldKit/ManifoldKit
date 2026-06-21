import SwiftUI

public struct LiveTranscriptionView: View {
    private let title: String
    private let text: String

    public init(text: String, title: String = "Voice draft") {
        self.title = title
        self.text = text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        // Mark this as a live region so VoiceOver re-reads the element as the
        // transcript grows during dictation, rather than treating it as a static
        // label the user must navigate back to.
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("voice-live-transcription")
        // Belt-and-suspenders for the live region: post an explicit announcement
        // when the transcript text changes so the update is spoken even if focus
        // isn't on the element.
        .onChange(of: text) { _, newValue in
            announce(newValue)
        }
    }

    private var accessibilityLabel: String {
        text.isEmpty ? title : "\(title): \(text)"
    }

    private func announce(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if os(iOS) || os(macOS)
        var announcement = AttributedString(trimmed)
        // High priority so a fresh transcript chunk interrupts the previous
        // (now-stale) announcement instead of queueing behind it.
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
        #endif
    }
}
