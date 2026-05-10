#if MCP
#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
@testable import ManifoldMCP
import ManifoldInference

actor MCPJSONLineProcessServer {
    private let package: String
    private let args: [String]
    private let codec = MCPJSONRPCCodec(maxMessageBytes: 4 * 1024 * 1024, maxJSONNestingDepth: 32)
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var nextRequestID = 1

    init(package: String, args: [String] = []) {
        self.package = package
        self.args = args
    }

    func start() async throws -> MCPCapabilities {
        guard process == nil else {
            throw MCPError.transportFailure("JSON-line MCP process already started")
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "-y", package] + args
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading

        let response = try await sendRequest(method: "initialize", params: .object([
            "protocolVersion": .string("2025-03-26"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("ManifoldKitE2E"),
                "version": .string("1.0.0"),
            ]),
        ]))
        try await sendNotification(method: "notifications/initialized", params: nil)
        return try parseInitializeResponse(response)
    }

    func sendRequest(method: String, params: JSONSchemaValue?) async throws -> JSONSchemaValue? {
        let id = MCPRequestID.int(nextRequestID)
        nextRequestID += 1
        let request = MCPJSONRPCMessage.request(id: id, method: method, params: params)
        try write(request)

        while true {
            let message = try readMessage()
            switch message {
            case .result(let responseID, let result) where responseID == id:
                return result
            case .error(let responseID, let error) where responseID == id:
                throw MCPError.protocolError(
                    code: error.code,
                    message: error.message,
                    data: error.data.flatMap(stringify)
                )
            case .request, .notification, .result, .error:
                continue
            }
        }
    }

    func sendNotification(method: String, params: JSONSchemaValue?) async throws {
        try write(.notification(method: method, params: params))
    }

    func close() {
        stdinHandle?.closeFile()
        stdoutHandle?.closeFile()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
    }

    private func write(_ message: MCPJSONRPCMessage) throws {
        guard let stdinHandle else { throw MCPError.transportClosed }
        var payload = try codec.encode(message)
        payload.append(0x0A)
        try stdinHandle.write(contentsOf: payload)
    }

    private func readMessage() throws -> MCPJSONRPCMessage {
        guard let stdoutHandle else { throw MCPError.transportClosed }
        var line = Data()
        while true {
            let byte = try stdoutHandle.read(upToCount: 1) ?? Data()
            if byte.isEmpty { throw MCPError.transportClosed }
            if byte[byte.startIndex] == 0x0A { break }
            line.append(byte)
        }
        if line.last == 0x0D {
            line.removeLast()
        }
        return try codec.decode(line)
    }

    private func parseInitializeResponse(_ response: JSONSchemaValue?) throws -> MCPCapabilities {
        guard case .object(let object) = response else {
            throw MCPError.malformedMetadata("Initialize response must be an object")
        }
        let capabilities = objectValue(object["capabilities"])
        let toolCapabilities = objectValue(capabilities?["tools"])
        return MCPCapabilities(
            protocolVersion: stringValue(object["protocolVersion"]) ?? "",
            serverName: objectValue(object["serverInfo"])?["name"].flatMap(stringValue) ?? package,
            serverVersion: objectValue(object["serverInfo"])?["version"].flatMap(stringValue) ?? "",
            supportsToolListChanged: toolCapabilities?["listChanged"].flatMap(boolValue) ?? true,
            supportsResources: capabilities?["resources"] != nil,
            supportsPrompts: capabilities?["prompts"] != nil,
            supportsLogging: capabilities?["logging"] != nil
        )
    }
}

func hasExecutableOnPATH(_ name: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", name]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func objectValue(_ value: JSONSchemaValue?) -> [String: JSONSchemaValue]? {
    guard case .object(let object) = value else { return nil }
    return object
}

private func stringValue(_ value: JSONSchemaValue?) -> String? {
    guard case .string(let string) = value else { return nil }
    return string
}

private func boolValue(_ value: JSONSchemaValue?) -> Bool? {
    guard case .bool(let bool) = value else { return nil }
    return bool
}

private func stringify(_ value: JSONSchemaValue) -> String {
    switch value {
    case .string(let string): return string
    default: return String(describing: value)
    }
}
#endif
#endif
