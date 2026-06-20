import SwiftUI
import ManifoldInference

/// A picker for the text-to-speech voice used by ``ChatViewModel/generateSpeech(forText:)``.
///
/// Lists installed voices grouped by quality tier (Premium → Enhanced →
/// Standard), best-first within each tier, plus an **Automatic** option that
/// lets the backend pick the best installed voice. The selection is bound to
/// ``ChatViewModel/selectedSpeechVoiceID``.
///
/// ```swift
/// VoicePickerView(viewModel: viewModel)        // all installed voices
/// VoicePickerView(viewModel: viewModel, language: "en")  // English only
/// ```
///
/// > Tip: The higher-quality (Enhanced/Premium) voices are downloaded by the
/// > user in *System Settings → Accessibility → Spoken Content → System Voice →
/// > Manage Voices*. Until then only Standard voices appear.
public struct VoicePickerView: View {

    @Bindable private var viewModel: ChatViewModel
    private let language: String?

    public init(viewModel: ChatViewModel, language: String? = nil) {
        self.viewModel = viewModel
        self.language = language
    }

    public var body: some View {
        let grouped = Dictionary(
            grouping: viewModel.availableSpeechVoices(language: language),
            by: \.quality
        )

        Picker("Voice", selection: $viewModel.selectedSpeechVoiceID) {
            Text("Automatic (best available)")
                .tag(String?.none)

            // Highest tier first so the most natural voices sit at the top.
            ForEach(VoiceDescriptor.Quality.allCases.sorted(by: >), id: \.self) { tier in
                if let voices = grouped[tier], !voices.isEmpty {
                    Section(tier.displayName) {
                        ForEach(voices) { voice in
                            Text("\(voice.name) · \(voice.language)")
                                .tag(String?.some(voice.id))
                        }
                    }
                }
            }
        }
    }
}
