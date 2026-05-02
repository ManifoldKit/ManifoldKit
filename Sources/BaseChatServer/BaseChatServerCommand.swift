#if Server
import ArgumentParser

@main
struct BaseChatServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "basechat-server",
        abstract: "Run an OpenAI-compatible BaseChatKit inference server."
    )

    @OptionGroup
    var options: ServerCommandOptions

    mutating func run() async throws {
        try options.validate()
        let selection = options.backendSelection()
        try selection.validate()
        let serverConfiguration = options.serverConfiguration()
        let provider = TraitAwareServerBackendProvider(selection: selection)
        let app = ServerApp(configuration: serverConfiguration, backendProvider: provider)
        try await app.run()
    }
}
#else
// Stub entry point when the `Server` trait is disabled. Building the
// executable still requires a `@main`; this prints a clear "trait not
// enabled" message instead of pulling Hummingbird into the default build.
@main
struct BaseChatServerDisabled {
    static func main() {
        print("BaseChatServer was built without the `Server` trait. Re-build with `--traits Server` to enable.")
    }
}
#endif
