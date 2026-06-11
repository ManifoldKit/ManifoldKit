import Darwin
import Foundation
import Security
import ManifoldInference

internal protocol MCPTransport: Sendable {
    var incomingMessages: AsyncThrowingStream<Data, Error> { get }
    func start() async throws
    func send(_ payload: Data) async throws
    func close() async
}

internal struct MCPTransportConfiguration: Sendable {
    let endpoint: URL
    let headers: [String: String]
    let authorization: any MCPAuthorization
    let sseLimits: SSEStreamLimits
    let maxMessageBytes: Int
    private let sessionProvider: @Sendable () throws -> URLSession

    init(
        endpoint: URL,
        headers: [String: String],
        authorization: any MCPAuthorization,
        sseLimits: SSEStreamLimits,
        maxMessageBytes: Int,
        session: URLSession
    ) {
        self.endpoint = endpoint
        self.headers = headers
        self.authorization = authorization
        self.sseLimits = sseLimits
        self.maxMessageBytes = maxMessageBytes
        self.sessionProvider = { session }
    }

    init(
        endpoint: URL,
        headers: [String: String],
        authorization: any MCPAuthorization,
        sseLimits: SSEStreamLimits,
        maxMessageBytes: Int
    ) {
        self.endpoint = endpoint
        self.headers = headers
        self.authorization = authorization
        self.sseLimits = sseLimits
        self.maxMessageBytes = maxMessageBytes
        self.sessionProvider = MCPURLSessionFactory.throwingShared
    }

    func session() throws -> URLSession {
        try sessionProvider()
    }
}

internal actor MCPStreamableHTTPTransport: MCPTransport {
    nonisolated let incomingMessages: AsyncThrowingStream<Data, Error>

    private let configuration: MCPTransportConfiguration
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var streamTask: Task<Void, Never>?

    init(configuration: MCPTransportConfiguration) {
        self.configuration = configuration
        let (incomingMessages, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        self.incomingMessages = incomingMessages
        self.continuation = continuation
    }

    func start() async throws {
        guard streamTask == nil else { return }
        try await startWithRetry(allowRetry: true)
    }

    private func startWithRetry(allowRetry: Bool) async throws {
        try await MCPSSRFPolicy.validateTransportRequestURL(configuration.endpoint)
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (name, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if let header = try await configuration.authorization.authorizationHeader(for: configuration.endpoint) {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }

        let connectionGuard = MCPRedirectCapDelegate(
            maxRedirects: 3,
            validator: MCPSSRFPolicy.validateTransportRedirectURL
        )
        let (bytes, response) = try await configuration.session().bytes(
            for: request,
            delegate: connectionGuard
        )
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transportFailure("Missing HTTP response")
        }
        // Gap C — DNS-rebinding TOCTOU. If the connection's metrics already report a
        // private/reserved remote address by the time headers arrive, block before
        // consuming any stream bytes. The guard also cancels the task on violation,
        // so a poisoned long-lived SSE connection detected mid-stream is torn down
        // and surfaces as a stream error below.
        if let blocked = connectionGuard.blockedConnectedURL {
            throw MCPError.ssrfBlocked(blocked)
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            switch try await configuration.authorization.handleUnauthorized(statusCode: http.statusCode, body: Data()) {
            case .retry where allowRetry:
                return try await startWithRetry(allowRetry: false)
            case .retry:
                throw MCPError.authorizationFailed("unauthorized")
            case .fail(let error):
                throw error
            }
        }

        guard (200...299).contains(http.statusCode) else {
            throw MCPError.transportFailure("SSE stream failed with status \(http.statusCode)")
        }

        streamTask = Task {
            do {
                let stream = SSEStreamParser.parseNamed(bytes: bytes, limits: configuration.sseLimits)
                for try await event in stream {
                    if Task.isCancelled { return }
                    if event.name == "ping" { continue }

                    let data = Data(event.data.utf8)
                    if data.count > configuration.maxMessageBytes {
                        throw MCPError.oversizeMessage(data.count)
                    }
                    continuation.yield(data)
                }
                continuation.finish()
            } catch {
                // A connection that rebinds to a private address mid-stream is
                // cancelled by the guard's metrics hook; surface it as ssrfBlocked
                // rather than a silent finish.
                if let blocked = connectionGuard.blockedConnectedURL {
                    continuation.finish(throwing: MCPError.ssrfBlocked(blocked))
                } else if error is CancellationError || Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func send(_ payload: Data) async throws {
        try await send(payload, allowRetry: true)
    }

    private func send(_ payload: Data, allowRetry: Bool) async throws {
        if payload.count > configuration.maxMessageBytes {
            throw MCPError.oversizeMessage(payload.count)
        }
        try await MCPSSRFPolicy.validateTransportRequestURL(configuration.endpoint)

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let header = try await configuration.authorization.authorizationHeader(for: configuration.endpoint) {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }

        let connectionGuard = MCPRedirectCapDelegate(
            maxRedirects: 3,
            validator: MCPSSRFPolicy.validateTransportRedirectURL
        )
        let (data, response) = try await configuration.session().data(
            for: request,
            delegate: connectionGuard
        )
        // Gap C — DNS-rebinding TOCTOU. `data(for:)` returns after the task
        // completes, by which point the connection's metrics report the address
        // URLSession actually connected to. If it was private/reserved, the
        // pre-flight check was bypassed by DNS rebinding — block before yielding
        // any response body.
        if let blocked = connectionGuard.blockedConnectedURL {
            throw MCPError.ssrfBlocked(blocked)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transportFailure("Missing HTTP response")
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            switch try await configuration.authorization.handleUnauthorized(statusCode: http.statusCode, body: data) {
            case .retry where allowRetry:
                return try await send(payload, allowRetry: false)
            case .retry:
                throw MCPError.authorizationFailed("unauthorized")
            case .fail(let error):
                throw error
            }
        }

        guard (200...299).contains(http.statusCode) else {
            throw MCPError.transportFailure("POST failed with status \(http.statusCode)")
        }

        guard !data.isEmpty else { return }
        if data.count > configuration.maxMessageBytes {
            throw MCPError.oversizeMessage(data.count)
        }
        continuation.yield(data)
    }

    func close() async {
        streamTask?.cancel()
        streamTask = nil
        continuation.finish()
    }
}

#if os(macOS) && !targetEnvironment(macCatalyst)
internal actor MCPStdioTransport: MCPTransport {
    nonisolated let incomingMessages: AsyncThrowingStream<Data, Error>

    private let command: MCPStdioCommand
    private let maxMessageBytes: Int
    private let inheritedEnvironment: [String: String]
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var readTask: Task<Void, Never>?

    init(
        command: MCPStdioCommand,
        maxMessageBytes: Int,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.command = command
        self.maxMessageBytes = maxMessageBytes
        self.inheritedEnvironment = inheritedEnvironment
        let (incomingMessages, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        self.incomingMessages = incomingMessages
        self.continuation = continuation
    }

    func start() async throws {
        guard process == nil else { return }
        try MCPStdioCommandValidator.validate(command)

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // Mark pipe descriptors close-on-exec so they are not inherited by any
        // additional child processes spawned later in the same process tree.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stdoutPipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stderrPipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)

        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = MCPStdioEnvironmentPolicy.sanitizedEnvironment(
            inherited: inheritedEnvironment,
            explicit: command.environment
        )
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let workingDirectory = command.workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        // Verify the executable meets the caller-supplied codesign requirement
        // before we give it access to our pipes. macOS only; the build condition
        // matches the outer #if that wraps MCPStdioTransport.
        #if os(macOS) && !targetEnvironment(macCatalyst)
        if let requirement = command.codesignRequirement {
            var staticCode: SecStaticCode?
            guard SecStaticCodeCreateWithPath(command.executable as CFURL, [], &staticCode) == errSecSuccess,
                  let code = staticCode else {
                throw MCPError.transportFailure("codesign check: could not create static code ref")
            }
            let req: SecRequirement? = try {
                var r: SecRequirement?
                guard SecRequirementCreateWithString(requirement as CFString, [], &r) == errSecSuccess else {
                    throw MCPError.transportFailure("codesign check: invalid requirement string")
                }
                return r
            }()
            guard SecStaticCodeCheckValidity(code, [], req) == errSecSuccess else {
                throw MCPError.transportFailure("codesign requirement not met: \(requirement)")
            }
        }
        #endif

        do {
            try process.run()
        } catch {
            throw MCPError.transportFailure("Failed to start stdio transport: \(error.localizedDescription)")
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let continuation = self.continuation
        let maxMessageBytes = self.maxMessageBytes
        self.readTask = Task.detached {
            await MCPStdioTransport.readOutputLoop(
                stdoutHandle: stdoutHandle,
                continuation: continuation,
                maxMessageBytes: maxMessageBytes
            )
        }
    }

    func send(_ payload: Data) async throws {
        if payload.count > maxMessageBytes {
            throw MCPError.oversizeMessage(payload.count)
        }
        guard let stdinHandle, let process, process.isRunning else {
            throw MCPError.transportClosed
        }

        do {
            try stdinHandle.write(contentsOf: MCPStdioFrameCodec.frame(payload))
        } catch {
            throw MCPError.transportFailure("Failed to write stdio payload: \(error.localizedDescription)")
        }
    }

    func close() async {
        readTask?.cancel()
        readTask = nil
        stdinHandle?.closeFile()

        if let process, process.isRunning {
            process.terminate()
            let exited = await MCPStdioTermination.waitForExit(process, timeout: .seconds(2))
            if exited == false {
                kill(process.processIdentifier, SIGKILL)
                _ = await MCPStdioTermination.waitForExit(process, timeout: .seconds(1))
            }
        }

        stdoutHandle?.closeFile()
        stderrHandle?.closeFile()
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        process = nil
        continuation.finish()
    }

    private nonisolated static func readOutputLoop(
        stdoutHandle: FileHandle,
        continuation: AsyncThrowingStream<Data, Error>.Continuation,
        maxMessageBytes: Int
    ) async {
        var parser = MCPStdioFrameCodec.Parser()
        do {
            while Task.isCancelled == false {
                guard let chunk = try await stdoutHandle.read(upToCount: 4096), chunk.isEmpty == false else {
                    break
                }
                try parser.append(chunk)
                while let payload = try parser.nextFrame(maxMessageBytes: maxMessageBytes) {
                    continuation.yield(payload)
                }
            }
            continuation.finish()
        } catch {
            if Task.isCancelled {
                continuation.finish()
            } else {
                continuation.finish(throwing: error)
            }
        }
    }
}

internal enum MCPStdioEnvironmentPolicy {
    private static let inheritedAllowlist: Set<String> = [
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "LOGNAME",
        "PATH",
        "SHELL",
        "TMPDIR",
        "USER",
        "__CF_USER_TEXT_ENCODING",
    ]

    static func sanitizedEnvironment(
        inherited: [String: String],
        explicit: [String: String]
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for (key, value) in inherited where inheritedAllowlist.contains(key) && value.contains("\u{0}") == false {
            environment[key] = value
        }
        for (key, value) in explicit where isValidEnvironmentName(key) && value.contains("\u{0}") == false {
            environment[key] = value
        }
        return environment
    }

    private static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first),
              name.unicodeScalars.dropFirst().allSatisfy({
                  $0 == "_" || CharacterSet.alphanumerics.contains($0)
              }) else {
            return false
        }
        return true
    }
}

private enum MCPStdioCommandValidator {
    private static let deniedShellExecutables: Set<String> = [
        "bash",
        "dash",
        "fish",
        "ksh",
        "sh",
        "zsh",
    ]

    static func validate(_ command: MCPStdioCommand) throws {
        guard command.executable.isFileURL else {
            throw MCPError.transportFailure("stdio executable must be a file URL")
        }
        guard deniedShellExecutables.contains(command.executable.lastPathComponent.lowercased()) == false else {
            throw MCPError.transportFailure("stdio executable must not be a shell")
        }
        if command.arguments.contains(where: { $0.contains("\u{0}") }) {
            throw MCPError.transportFailure("stdio arguments must not contain NUL bytes")
        }
        if let workingDirectory = command.workingDirectory, workingDirectory.isFileURL == false {
            throw MCPError.transportFailure("stdio working directory must be a file URL")
        }
    }
}

private enum MCPStdioTermination {
    static func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while process.isRunning {
            if clock.now >= deadline {
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
        }
        return true
    }
}

private enum MCPStdioFrameCodec {
    static func frame(_ payload: Data) -> Data {
        var framed = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        framed.append(payload)
        return framed
    }

    struct Parser {
        private static let delimiter = Data("\r\n\r\n".utf8)
        private static let maxHeaderBytes = 8 * 1024

        private var buffer = Data()

        mutating func append(_ bytes: Data) throws {
            buffer.append(bytes)
            if buffer.count > Self.maxHeaderBytes && buffer.range(of: Self.delimiter) == nil {
                throw MCPError.transportFailure("stdio header exceeds maximum size")
            }
        }

        mutating func nextFrame(maxMessageBytes: Int) throws -> Data? {
            guard let delimiterRange = buffer.range(of: Self.delimiter) else { return nil }
            let headerData = buffer[..<delimiterRange.lowerBound]
            guard let headerString = String(data: headerData, encoding: .utf8) else {
                throw MCPError.transportFailure("stdio header is not valid UTF-8")
            }
            let contentLength = try parseContentLength(headerString)
            if contentLength > maxMessageBytes {
                throw MCPError.oversizeMessage(contentLength)
            }

            let frameStart = delimiterRange.upperBound
            let available = buffer.distance(from: frameStart, to: buffer.endIndex)
            guard available >= contentLength else { return nil }

            let payloadEnd = buffer.index(frameStart, offsetBy: contentLength)
            let payload = Data(buffer[frameStart..<payloadEnd])
            buffer.removeSubrange(..<payloadEnd)
            return payload
        }

        private func parseContentLength(_ headers: String) throws -> Int {
            let lines = headers.components(separatedBy: "\r\n")
            guard let lengthHeader = lines.first(where: {
                $0.lowercased().hasPrefix("content-length:")
            }) else {
                throw MCPError.transportFailure("stdio frame missing Content-Length header")
            }

            let value = lengthHeader.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            guard let length = Int(value), length >= 0 else {
                throw MCPError.transportFailure("stdio frame has invalid Content-Length header")
            }
            return length
        }
    }
}
#endif
