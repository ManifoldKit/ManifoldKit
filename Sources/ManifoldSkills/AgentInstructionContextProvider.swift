import Foundation
import ManifoldInference

/// A ``PromptContextProvider`` that injects merged ``AGENTS.md`` ambient
/// instructions into the system preamble at turn assembly time.
///
/// Wire this into a ``PromptContextPipeline`` to give every session transparent
/// access to project- and user-level `AGENTS.md` instructions:
///
/// ```swift
/// // swift,no-build
/// let agentsProvider = AgentInstructionContextProvider(
///     currentDirectory: projectRoot,
///     stoppingAt: homeDirectory
/// )
/// let pipeline = PromptContextPipeline(providers: [agentsProvider])
/// ```
///
/// The slot is placed at ``PromptSlotPosition/systemPreamble`` so it sits
/// before conversation history and after any host-supplied system prompt.
///
/// **Opt-in by design.** The session-level "current directory" scoping model
/// (which directory to resolve `AGENTS.md` from, per session) is undesigned
/// as of v1 (#1943). Hosts supply `currentDirectory` at construction time.
///
/// - Note: ``AgentInstructionLoader/discover(from:stoppingAt:)`` performs
///   synchronous file I/O. `AGENTS.md` files are expected to be small
///   (< 64 KB); the blocking duration is negligible. A future revision may
///   add async file reading if this assumption changes.
public struct AgentInstructionContextProvider: PromptContextProvider {

    private let loader: AgentInstructionLoader
    private let currentDirectory: URL
    private let stopDirectory: URL?

    /// Creates a provider that discovers `AGENTS.md` files from `currentDirectory`
    /// upward to `stopDirectory` (or home if nil).
    public init(
        currentDirectory: URL,
        stoppingAt stopDirectory: URL? = nil,
        loader: AgentInstructionLoader = AgentInstructionLoader()
    ) {
        self.currentDirectory = currentDirectory
        self.stopDirectory = stopDirectory
        self.loader = loader
    }

    public func contributeSlots(messageCount: Int) async throws -> [PromptSlot] {
        guard let merged = loader.loadMerged(
            from: currentDirectory,
            stoppingAt: stopDirectory
        ) else {
            return []
        }
        return [
            PromptSlot(
                id: "agents-md-ambient",
                content: merged,
                position: .systemPreamble,
                role: .userInstruction,
                label: "AGENTS.md ambient instructions"
            )
        ]
    }
}
