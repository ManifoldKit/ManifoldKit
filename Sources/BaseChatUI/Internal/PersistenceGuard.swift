import Foundation
import BaseChatRuntime
import BaseChatInference

// MARK: - Persistence guard helpers
//
// View models in this module repeatedly check `persistence != nil` before
// touching the configured store. The two helpers below centralize that
// check so call sites stop reinventing the same `guard let persistence else
// { Log.persistence.warning(...); return/throw }` block.
//
// - `requirePersistence(_:)` is for code paths that propagate a missing
//   store as a `ChatPersistenceError.providerNotConfigured` to the caller.
// - `persistenceOrLog(_:)` is for code paths that no-op (returning early) when
//   persistence is unavailable — typically `loadMessages`-style read-or-skip
//   methods.
//
// Both helpers log via `Log.persistence` and include `#fileID:#line` so the
// emitted warning still points back at the calling method even though the
// guard itself lives here.

@inline(__always)
private func logMissingPersistence(
    _ context: String,
    fileID: StaticString,
    line: UInt
) {
    // The OSLog macro captures interpolated arguments in an escaping closure,
    // so we materialise the context string before handing it off rather than
    // passing an `@autoclosure` parameter through the interpolation directly.
    Log.persistence.warning(
        "\(context, privacy: .public) called before persistence was configured (\(fileID, privacy: .public):\(line, privacy: .public))"
    )
}

extension SessionController {
    func requirePersistence(
        _ context: @autoclosure () -> String,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) throws -> any SessionStore & MessageStore {
        guard let persistence else {
            logMissingPersistence(context(), fileID: fileID, line: line)
            throw ChatPersistenceError.providerNotConfigured
        }
        return persistence
    }

    func persistenceOrLog(
        _ context: @autoclosure () -> String,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) -> (any SessionStore & MessageStore)? {
        guard let persistence else {
            logMissingPersistence(context(), fileID: fileID, line: line)
            return nil
        }
        return persistence
    }
}

extension SessionManagerViewModel {
    func requirePersistence(
        _ context: @autoclosure () -> String,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) throws -> any SessionStore & MessageStore {
        guard let persistence else {
            logMissingPersistence(context(), fileID: fileID, line: line)
            throw ChatPersistenceError.providerNotConfigured
        }
        return persistence
    }

    func persistenceOrLog(
        _ context: @autoclosure () -> String,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) -> (any SessionStore & MessageStore)? {
        guard let persistence else {
            logMissingPersistence(context(), fileID: fileID, line: line)
            return nil
        }
        return persistence
    }
}

extension ChatViewModel {
    func requirePersistence(
        _ context: @autoclosure () -> String,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) throws -> any SessionStore & MessageStore {
        guard let persistence else {
            logMissingPersistence(context(), fileID: fileID, line: line)
            throw ChatPersistenceError.providerNotConfigured
        }
        return persistence
    }

    func persistenceOrLog(
        _ context: @autoclosure () -> String,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) -> (any SessionStore & MessageStore)? {
        guard let persistence else {
            logMissingPersistence(context(), fileID: fileID, line: line)
            return nil
        }
        return persistence
    }
}
