#if Server
import ArgumentParser

/// The `manifold-server` CLI's parsed command. Lives in the library target
/// (not the `ManifoldServerCLI` executable target) so it stays a plain type —
/// `@main` can only annotate a type in an executable target, so the actual
/// entry point is `ManifoldServerCLIEntryPoint` in `Sources/ManifoldServerCLI`,
/// which just calls `ManifoldServerCommand.main()`. `package` (not `internal`)
/// because that entry point lives in a different target within this package.
package struct ManifoldServerCommand: AsyncParsableCommand {
    package static let configuration = CommandConfiguration(
        commandName: "manifold-server",
        abstract: "Run an OpenAI-compatible ManifoldKit inference server."
    )

    @OptionGroup
    package var options: ServerCommandOptions

    package init() {}

    package mutating func run() async throws {
        try options.validate()
        let selection = options.backendSelection()
        try selection.validate()
        let serverConfiguration = options.serverConfiguration()
        let provider = TraitAwareServerBackendProvider(selection: selection)
        let app = ServerApp(configuration: serverConfiguration, backendProvider: provider)
        try await app.run()
    }
}
#endif
