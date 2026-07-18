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
        let app = try buildApp()
        try await app.run()
    }

    /// Builds the configured `ServerApp` without starting the network
    /// listener, split out from `run()` so tests can exercise the
    /// validate-and-configure path in isolation.
    ///
    /// `options` is an `@OptionGroup`, so ArgumentParser already invoked
    /// `ServerCommandOptions.validate()` once while decoding the parsed
    /// command (`OptionGroup.init(from:)`), before `run()` was ever reached —
    /// a second explicit `try options.validate()` call here used to
    /// duplicate the --allow-anonymous security warning on every boot.
    /// `selection` is built manually below (not part of the parsed argument
    /// tree), so it still needs its own explicit `validate()` call.
    internal func buildApp() throws -> ServerApp {
        let selection = options.backendSelection()
        try selection.validate()
        let serverConfiguration = options.serverConfiguration()
        let provider = TraitAwareServerBackendProvider(selection: selection)
        return ServerApp(configuration: serverConfiguration, backendProvider: provider)
    }
}
#endif
