import ArgumentParser
import BaseChatServerBackends
import BaseChatServerCore

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
