import Foundation
import BaseChatInference

/// UI-only presentation metadata for failed tool results.
public struct ToolErrorPresentation: Sendable, Equatable {
    public struct ReauthenticationCTA: Sendable, Equatable {
        public let actionID: String
        public let label: String
        public let message: String
        public let serviceName: String

        public init(actionID: String, label: String, message: String, serviceName: String) {
            self.actionID = actionID
            self.label = label
            self.message = message
            self.serviceName = serviceName
        }
    }

    public let summary: String
    public let reauthenticationCTA: ReauthenticationCTA?

    public init(errorKind: ToolResult.ErrorKind?, toolName: String?) {
        guard let errorKind else {
            self.summary = String(localized: "tool.error.generic", defaultValue: "The tool call failed.")
            self.reauthenticationCTA = nil
            return
        }

        self.summary = errorKind.localizedDescription
        if errorKind == .permissionDenied, let toolName, toolName.isEmpty == false {
            let serviceName = Self.serviceName(from: toolName)
            self.reauthenticationCTA = ReauthenticationCTA(
                actionID: "mcp.reauthenticate.\(Self.serviceKey(from: toolName))",
                label: String(localized: "tool.error.permissionDenied.signIn", defaultValue: "Tap to sign in"),
                message: String(
                    localized: "tool.error.permissionDenied.connected",
                    defaultValue: "\(serviceName) isn't connected. Tap to sign in."
                ),
                serviceName: serviceName
            )
        } else {
            self.reauthenticationCTA = nil
        }
    }

    private static func serviceKey(from toolName: String) -> String {
        if let namespaceRange = toolName.range(of: "__") {
            return String(toolName[..<namespaceRange.lowerBound])
        }
        return toolName
    }

    private static func serviceName(from toolName: String) -> String {
        let key = serviceKey(from: toolName)
        return key
            .split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." })
            .map { word in
                let lower = word.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
}
