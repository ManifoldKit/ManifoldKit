import SwiftUI
import ManifoldInference

#if canImport(ManifoldAppIntents)
import ManifoldAppIntents

/// Demo screen that registers a real AppIntent (``SetReminderIntent``) on the
/// chat tool registry via ``AppIntentToolExecutor``.
///
/// The tool appears in the model's tool list as `set_reminder_intent` once
/// the user taps "Register". Subsequent chat turns can invoke it the same way
/// the rest of the demo's tools (calc, now, read_file…) get invoked.
@available(iOS 26, macOS 26, *)
struct AppIntentToolsView: View {

    @Environment(\.dismiss) private var dismiss

    let toolRegistry: ToolRegistry

    @State private var registered: Bool = false
    @State private var lastSchema: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section("AppIntent → Tool") {
                    Text("ManifoldAppIntents bridges any `AppIntent` into the chat tool registry. Tapping `Register` exposes the demo's `SetReminderIntent` to the model under the name `set_reminder_intent`.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button(registered ? "Registered" : "Register SetReminderIntent") {
                        register()
                    }
                    .disabled(registered)
                    .accessibilityIdentifier("appintent-tools-register-button")
                }

                if !lastSchema.isEmpty {
                    Section("Synthesised JSON Schema") {
                        Text(lastSchema)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("appintent-tools-schema")
                    }
                }
            }
            .navigationTitle("AppIntent Tools")
            .accessibilityIdentifier("appintent-tools-sheet")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                lastSchema = AppIntentToolsView.schemaPreview()
            }
        }
    }

    private func register() {
        let executor = AppIntentToolExecutor(SetReminderIntent.self)
        toolRegistry.register(executor)
        registered = true
        lastSchema = AppIntentToolsView.schemaPreview()
    }

    private static func schemaPreview() -> String {
        let executor = AppIntentToolExecutor(SetReminderIntent.self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(executor.definition.parameters),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "<unable to render schema>"
    }
}

#endif
