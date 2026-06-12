#if Server
import ArgumentParser

@main
struct ManifoldServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manifold-server",
        abstract: "Run an OpenAI-compatible ManifoldKit inference server."
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
struct ManifoldServerDisabled {
    static func main() {
        print("ManifoldServer was built without the `Server` trait. Re-build with `--traits Server` to enable.")
    }
}
#endif
