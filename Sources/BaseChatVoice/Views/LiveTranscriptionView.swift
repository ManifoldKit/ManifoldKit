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
        .accessibilityLabel("\(title): \(text)")
        .accessibilityIdentifier("voice-live-transcription")
    }
}
