import SwiftUI
import ManifoldRuntime
import ManifoldInference
import UniformTypeIdentifiers
#if os(iOS)
import AVFoundation
#endif

/// The text input bar at the bottom of the chat view.
///
/// Shows a multiline text field with send/stop buttons plus an image-attachment
/// affordance when the active backend reports vision support. On compact size
/// class (iPhone), a row of quick-action pills appears above the input for
/// common prompts like "Continue" and "Describe scene".
public struct ChatInputBar: View {

    @Environment(ChatViewModel.self) private var viewModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    @FocusState private var isInputFocused: Bool
    @State private var isImageImporterPresented = false
#if os(iOS)
    @State private var audioRecorder: AVAudioRecorder?
    @State private var isRecordingAudio = false
#endif

    public init() {}

    // MARK: - Body

    private var inputPlaceholder: String {
        if viewModel.isLoading { return "Loading model…" }
        if viewModel.activeSession == nil { return "No session selected" }
        if !viewModel.isModelLoaded { return "No model loaded" }
        return "Message…"
    }

    public var body: some View {
        @Bindable var viewModel = viewModel

        VStack(spacing: 8) {
            if sizeClass == .compact {
                quickActionPills
            }

            if !viewModel.draftAttachments.isEmpty {
                draftAttachmentStrip
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(inputPlaceholder, text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($isInputFocused)
                    .padding(10)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                    .disabled(viewModel.activeSession == nil || !viewModel.isModelLoaded || viewModel.isLoading)
                    .accessibilityLabel("Message input")

                actionButtons
            }
        }
        .fileImporter(
            isPresented: $isImageImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleImageImport(result)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            if viewModel.supportsImageAttachments {
                attachImageButton
            }

#if os(iOS)
            recordAudioButton
#endif

            if showRegenerateButton {
                Button {
                    Task {
                        await viewModel.regenerateLastResponse()
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Regenerate last response")
                .help("Regenerate last response")
            }

            sendOrStopButton
        }
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        SendStopButton(
            isGenerating: viewModel.isGenerating,
            canSend: canSend,
            onSend: sendMessage,
            onStop: { viewModel.stopGeneration() }
        )
    }

    private var attachImageButton: some View {
        Button {
            isImageImporterPresented = true
        } label: {
            Image(systemName: "paperclip.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!canAttachImage)
        .accessibilityLabel("Attach image")
        .help("Attach image")
    }

#if os(iOS)
    private var recordAudioButton: some View {
        Button {
            toggleAudioRecording()
        } label: {
            Image(systemName: isRecordingAudio ? "stop.circle.fill" : "mic.circle.fill")
                .font(.title2)
                .foregroundStyle(isRecordingAudio ? .red : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(!isRecordingAudio && !canRecordAudio)
        .accessibilityLabel(isRecordingAudio ? "Stop recording audio" : "Record audio message")
        .help(isRecordingAudio ? "Stop recording audio" : "Record audio message")
    }
#endif

    // MARK: - Quick Action Pills

    private var quickActionPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                quickActionPill("Continue") {
                    sendQuickAction("Continue")
                }
                quickActionPill("Summarize") {
                    sendQuickAction("Summarize")
                }
                quickActionPill("Explain more") {
                    sendQuickAction("Explain more")
                }
                quickActionPill("Give an example") {
                    sendQuickAction("Give an example")
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func quickActionPill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.fill.tertiary, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.activeSession == nil || !viewModel.isModelLoaded || viewModel.isGenerating || viewModel.isLoading)
        .accessibilityLabel(title)
        .accessibilityHint("Sends \"\(title)\" as a message")
    }

    // MARK: - Helpers

    private var canSend: Bool {
        viewModel.activeSession != nil
        && viewModel.isModelLoaded
        && !viewModel.isGenerating
        && !viewModel.isLoading
        && viewModel.hasDraftContent
    }

    private var canAttachImage: Bool {
        viewModel.activeSession != nil
        && viewModel.isModelLoaded
        && !viewModel.isGenerating
        && !viewModel.isLoading
    }

#if os(iOS)
    private var canRecordAudio: Bool {
        viewModel.activeSession != nil
        && viewModel.isModelLoaded
        && !viewModel.isGenerating
        && !viewModel.isLoading
    }
#endif

    private var showRegenerateButton: Bool {
        !viewModel.isGenerating
        && !viewModel.messages.isEmpty
        && viewModel.messages.last?.role == .assistant
    }

    private func sendMessage() {
        guard canSend else { return }
        Task {
            await viewModel.sendMessage()
        }
    }

    private func sendQuickAction(_ text: String) {
        viewModel.inputText = text
        Task {
            await viewModel.sendMessage()
        }
    }

#if os(iOS)
    private func toggleAudioRecording() {
        if isRecordingAudio {
            finishAudioRecording()
        } else {
            Task { await beginAudioRecording() }
        }
    }

    private func beginAudioRecording() async {
        guard canRecordAudio else { return }
        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        guard granted else {
            viewModel.surfaceError(
                InferenceError.inferenceFailure("Microphone access is required to record audio messages."),
                kind: .configuration,
                context: "recording audio"
            )
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)

            let url = try makeAudioRecordingURL()
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            guard recorder.record() else {
                throw InferenceError.inferenceFailure("Unable to start audio recording.")
            }
            audioRecorder = recorder
            isRecordingAudio = true
        } catch {
            viewModel.surfaceError(error, kind: .configuration, context: "recording audio")
            deactivateRecordingSession()
        }
    }

    private func finishAudioRecording() {
        guard let recorder = audioRecorder else { return }
        let url = recorder.url.standardizedFileURL
        let duration = recorder.currentTime
        recorder.stop()
        audioRecorder = nil
        isRecordingAudio = false
        deactivateRecordingSession()

        guard duration > 0.1 else {
            deleteRecordingIfPresent(at: url)
            return
        }

        viewModel.stageDraftAttachment(.audio(
            url: url,
            duration: duration,
            waveform: waveformSamples(for: url)
        ))
    }

    private func makeAudioRecordingURL() throws -> URL {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw InferenceError.inferenceFailure("Unable to locate an audio recording directory.")
        }
        let directory = root.appendingPathComponent("ManifoldKit/AudioMessages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString).m4a")
    }

    private func waveformSamples(for url: URL, targetCount: Int = 48) -> [Float]? {
        guard url.isFileURL, targetCount > 0 else { return nil }
        do {
            let file = try AVAudioFile(forReading: url)
            let frameCount = AVAudioFrameCount(min(file.length, Int64(44_100 * 60 * 10)))
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
                return nil
            }
            try file.read(into: buffer, frameCount: frameCount)
            guard let channel = buffer.floatChannelData?[0] else { return nil }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return nil }
            let bucketSize = max(frames / targetCount, 1)
            var samples: [Float] = []
            samples.reserveCapacity(targetCount)
            for start in stride(from: 0, to: frames, by: bucketSize) {
                let end = min(start + bucketSize, frames)
                var peak: Float = 0
                for frame in start..<end {
                    peak = max(peak, abs(channel[frame]))
                }
                samples.append(peak)
                if samples.count == targetCount { break }
            }
            let maxPeak = samples.max() ?? 0
            guard maxPeak > 0 else { return samples }
            return samples.map { min(max($0 / maxPeak, 0), 1) }
        } catch {
            Log.ui.warning("Failed to compute audio waveform: \(error)")
            return nil
        }
    }

    private func deactivateRecordingSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            Log.ui.warning("Failed to deactivate audio recording session: \(error)")
        }
    }

    private func deleteRecordingIfPresent(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            Log.ui.warning("Failed to remove discarded audio recording: \(error)")
        }
    }
#endif

    @ViewBuilder
    private var draftAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(viewModel.draftAttachments.enumerated()), id: \.offset) { index, part in
                    draftAttachmentPreview(for: part, at: index)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func draftAttachmentPreview(for part: MessagePart, at index: Int) -> some View {
        if case let .image(data, _, placeholderHash) = part {
            ZStack(alignment: .topTrailing) {
                draftThumbnail(data: data, placeholderHash: placeholderHash)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                Button {
                    viewModel.removeDraftAttachment(id: index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white, .black.opacity(0.7))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("Remove attachment")
            }
            .padding(.trailing, 4)
        } else if case let .audio(_, duration, _) = part {
            ZStack(alignment: .topTrailing) {
                Label("Audio \(formattedAudioDuration(duration))", systemImage: "waveform")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.fill.tertiary, in: Capsule())

                Button {
                    viewModel.removeDraftAttachment(id: index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white, .black.opacity(0.7))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("Remove audio attachment")
            }
            .padding(.trailing, 4)
        }
    }

    private func formattedAudioDuration(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "0:00" }
        let totalSeconds = max(Int(value.rounded()), 0)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    @ViewBuilder
    private func draftThumbnail(data: Data, placeholderHash: ImagePlaceholderHash?) -> some View {
        #if os(iOS)
        if let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            ImagePlaceholderView(placeholderHash: placeholderHash)
        }
        #elseif os(macOS)
        if let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
        } else {
            ImagePlaceholderView(placeholderHash: placeholderHash)
        }
        #endif
    }

    private func handleImageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // Resolve the MIME type synchronously while the security-scoped
            // resource is open — resourceValues is a fast metadata-only call.
            // The actual file read is dispatched to a background task so it
            // never blocks the main thread on large images.
            let accessed = url.startAccessingSecurityScopedResource()
            let mimeType: String
            do {
                mimeType = try resolvedImageMIMEType(for: url)
            } catch {
                if accessed { url.stopAccessingSecurityScopedResource() }
                viewModel.surfaceError(error, kind: .configuration, context: "attaching image")
                return
            }

            // Capture everything needed by the background task; the
            // security-scoped resource remains open until the task releases it.
            let capturedURL = url
            let capturedMIMEType = mimeType
            let capturedAccessed = accessed
            Task {
                defer {
                    if capturedAccessed { capturedURL.stopAccessingSecurityScopedResource() }
                }
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: capturedURL)
                    }.value
                    viewModel.stageDraftAttachment(.image(data: data, mimeType: capturedMIMEType))
                } catch {
                    viewModel.surfaceError(error, kind: .configuration, context: "attaching image")
                }
            }

        case .failure(let error):
            viewModel.surfaceError(error, kind: .configuration, context: "attaching image")
        }
    }

    private func resolvedImageMIMEType(for url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.contentTypeKey])
        let contentType = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        guard let contentType,
              contentType.conforms(to: .image),
              let mimeType = contentType.preferredMIMEType else {
            throw InferenceError.inferenceFailure("Unsupported image attachment type.")
        }
        return mimeType
    }
}

// MARK: - Send/Stop Button

/// The primary send-or-stop button rendered at the trailing edge of the chat
/// input bar. Extracted as a standalone view so its accessibility contract can
/// be inspected in unit tests without mounting a full `ChatViewModel`.
struct SendStopButton: View {

    /// Accessibility label used while the assistant is generating a response.
    static let stopLabel = "Stop generation"
    /// Accessibility label used when the button will send the composed message.
    static let sendLabel = "Send message"

    let isGenerating: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    init(
        isGenerating: Bool,
        canSend: Bool,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.isGenerating = isGenerating
        self.canSend = canSend
        self.onSend = onSend
        self.onStop = onStop
    }

    var body: some View {
        if isGenerating {
            Button(action: onStop) {
                Image(systemName: "stop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.stopLabel)
            .help(Self.stopLabel)
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? Color.accentColor : Color.gray)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(Self.sendLabel)
            .help("\(Self.sendLabel) (Cmd+Return)")
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Spacer()
        Divider()
        ChatInputBar()
    }
    .environment(ChatViewModel())
}
