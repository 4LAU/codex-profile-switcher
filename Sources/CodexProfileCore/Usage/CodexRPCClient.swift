import Foundation

public enum CodexRPCError: LocalizedError {
    case cliNotFound
    case startFailed(String)
    case requestFailed(String)
    case malformed(String)
    case timeout(method: String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Codex CLI not found"
        case .startFailed(let message):
            return "Failed to start Codex CLI: \(message)"
        case .requestFailed(let message):
            return message
        case .malformed(let message):
            return message
        case .timeout(let method):
            return "Codex CLI timed out on \(method)"
        }
    }

    public var isAuthRequired: Bool {
        guard case .requestFailed(let message) = self else { return false }
        let terms = [
            "authentication required",
            "log in",
            "login required",
            "unauthorized",
            "token expired",
            "expired token",
            "invalid_grant",
            "refresh token",
        ]
        return terms.contains { message.localizedCaseInsensitiveContains($0) }
    }
}

public enum CLIUsageError: LocalizedError {
    case noRateLimitsFound
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .noRateLimitsFound:
            return "Codex CLI returned no usage data"
        case .invalidResponse(let message):
            return message
        }
    }
}

private struct RPCRateLimitsResponse: Decodable {
    let rateLimits: RPCRateLimitSnapshot
}

private struct RPCRateLimitSnapshot: Decodable {
    let primary: RPCRateLimitWindow?
    let secondary: RPCRateLimitWindow?
    let credits: RPCCreditsSnapshot?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case credits
        case planType = "planType"
    }
}

private struct RPCRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
}

private struct RPCCreditsSnapshot: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

public enum CodexCLIResolver {
    private static let fileManager = FileManager.default

    public static func resolvePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let override = environment["CODEX_CLI"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           self.fileManager.isExecutableFile(atPath: override) {
            return override
        }

        let bundledRoot = environment["CODEX_APP"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "/Applications/Codex.app"
        let bundledCLI = URL(fileURLWithPath: bundledRoot)
            .appendingPathComponent("Contents/Resources/codex")
            .path
        if self.fileManager.isExecutableFile(atPath: bundledCLI) {
            return bundledCLI
        }

        if let fromPath = self.whichCodex(environment: environment) {
            return fromPath
        }

        return nil
    }

    private static func whichCodex(environment: [String: String]) -> String? {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["codex"]
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        var env = environment
        env["PATH"] = self.effectivePATH(environment: environment)
        proc.environment = env

        do {
            try proc.run()
        } catch {
            return nil
        }

        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func effectivePATH(environment: [String: String]) -> String {
        let home = self.fileManager.homeDirectoryForCurrentUser.path
        let defaults = [
            environment["PATH"],
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]

        var seen = Set<String>()
        var parts: [String] = []
        for chunk in defaults.compactMap({ $0 }) {
            for item in chunk.split(separator: ":").map(String.init) where !item.isEmpty {
                if seen.insert(item).inserted {
                    parts.append(item)
                }
            }
        }
        return parts.joined(separator: ":")
    }
}

final class CodexRPCLineBuffer {
    private let lock = NSLock()
    private var buffer = Data()
    private static let maxBufferBytes = 4 * 1024 * 1024  // 4 MB cap

    /// Returns complete newline-delimited lines drained from the buffer.
    /// If the buffer exceeds maxBufferBytes without a newline, it is cleared and
    /// `nil` is returned to signal a malformed-stream condition.
    func appendAndDrainLines(_ data: Data) -> (lines: [Data], overflow: Bool) {
        self.lock.lock()
        defer { self.lock.unlock() }

        self.buffer.append(data)

        if self.buffer.count > CodexRPCLineBuffer.maxBufferBytes {
            let overflowBytes = self.buffer.count
            self.buffer.removeAll(keepingCapacity: false)
            CoreLogger.warning(
                "CodexRPCLineBuffer: buffer exceeded 4 MB cap; clearing",
                metadata: ["bytes": "\(overflowBytes)"])
            return ([], true)
        }

        var out: [Data] = []
        while let newline = self.buffer.firstIndex(of: 0x0A) {
            let line = Data(self.buffer[..<newline])
            self.buffer.removeSubrange(...newline)
            if !line.isEmpty {
                out.append(line)
            }
        }
        return (out, false)
    }
}

private final class CodexRPCClient {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutLineStream: AsyncStream<Data>
    private let stdoutLineContinuation: AsyncStream<Data>.Continuation
    private let initializeTimeoutSeconds: TimeInterval
    private let requestTimeoutSeconds: TimeInterval
    private var nextID = 1
    private var stdoutLineIterator: AsyncStream<Data>.Iterator

    init(
        executablePath: String,
        environment: [String: String],
        initializeTimeoutSeconds: TimeInterval = 8,
        requestTimeoutSeconds: TimeInterval = 3) throws
    {
        self.initializeTimeoutSeconds = initializeTimeoutSeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds

        var continuation: AsyncStream<Data>.Continuation!
        self.stdoutLineStream = AsyncStream<Data> { continuation = $0 }
        self.stdoutLineContinuation = continuation
        self.stdoutLineIterator = self.stdoutLineStream.makeAsyncIterator()

        self.process.executableURL = URL(fileURLWithPath: executablePath)
        self.process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]
        self.process.environment = environment
        self.process.standardInput = self.stdinPipe
        self.process.standardOutput = self.stdoutPipe
        self.process.standardError = self.stderrPipe

        do {
            try self.process.run()
        } catch {
            throw CodexRPCError.startFailed(error.localizedDescription)
        }

        let stdoutHandle = self.stdoutPipe.fileHandleForReading
        let stdoutBuffer = CodexRPCLineBuffer()
        let stdoutContinuation = self.stdoutLineContinuation
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutContinuation.finish()
                return
            }

            let result = stdoutBuffer.appendAndDrainLines(data)
            if result.overflow {
                handle.readabilityHandler = nil
                stdoutContinuation.finish()
                return
            }
            for line in result.lines {
                stdoutContinuation.yield(line)
            }
        }

        let stderrHandle = self.stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
        }
    }

    func initialize(clientName: String, clientVersion: String) async throws {
        _ = try await self.request(
            method: "initialize",
            params: ["clientInfo": ["name": clientName, "version": clientVersion]],
            timeout: self.initializeTimeoutSeconds)
        try self.sendNotification(method: "initialized")
    }

    func fetchRateLimits() async throws -> RPCRateLimitsResponse {
        let message = try await self.request(method: "account/rateLimits/read")
        return try self.decodeResult(from: message)
    }

    func shutdown() {
        self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        self.stderrPipe.fileHandleForReading.readabilityHandler = nil
        guard self.process.isRunning else { return }
        self.process.terminate()

        // Wait up to ~2 s for the process to exit before allowing the caller's
        // defer to delete the temp CODEX_HOME the child may still be using.
        let deadline = Date(timeIntervalSinceNow: 2.0)
        while self.process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if self.process.isRunning {
            kill(self.process.processIdentifier, SIGKILL)
            // One short final wait so the OS can reclaim the PID.
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private struct SendableMessage: @unchecked Sendable {
        let value: [String: Any]
    }

    private func request(
        method: String,
        params: [String: Any]? = nil,
        timeout: TimeInterval? = nil) async throws -> [String: Any]
    {
        let id = self.nextID
        self.nextID += 1
        try self.sendRequest(id: id, method: method, params: params)

        let resolvedTimeout = timeout ?? self.requestTimeoutSeconds
        let wrapped = try await self.withTimeout(seconds: resolvedTimeout, method: method) {
            while true {
                let message = try await self.readNextMessage()

                if message["id"] == nil {
                    continue
                }

                guard let messageID = self.jsonID(message["id"]), messageID == id else { continue }

                if let error = message["error"] as? [String: Any],
                   let messageText = error["message"] as? String {
                    throw CodexRPCError.requestFailed(messageText)
                }

                return SendableMessage(value: message)
            }
        }
        return wrapped.value
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        method: String,
        body: @escaping @Sendable () async throws -> T) async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await body()
            }
            group.addTask { [weak self] in
                try await Task.sleep(for: .seconds(seconds))
                self?.terminateForTimeout()
                throw CodexRPCError.timeout(method: method)
            }
            guard let result = try await group.next() else {
                group.cancelAll()
                throw CodexRPCError.timeout(method: method)
            }
            group.cancelAll()
            return result
        }
    }

    private func terminateForTimeout() {
        if self.process.isRunning {
            self.process.terminate()
        }
    }

    private func sendNotification(method: String, params: [String: Any]? = nil) throws {
        try self.sendPayload(["jsonrpc": "2.0", "method": method, "params": params ?? [:]])
    }

    private func sendRequest(id: Int, method: String, params: [String: Any]?) throws {
        try self.sendPayload(["jsonrpc": "2.0", "id": id, "method": method, "params": params ?? [:]])
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        try self.stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func readNextMessage() async throws -> [String: Any] {
        while let lineData = await self.stdoutLineIterator.next() {
            if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                return json
            }
        }
        throw CodexRPCError.malformed("codex app-server closed stdout")
    }

    private func decodeResult<T: Decodable>(from message: [String: Any]) throws -> T {
        guard let result = message["result"] else {
            throw CodexRPCError.malformed("missing result field")
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func jsonID(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }
}

public enum CLIUsageFetcher {
    public static func fetch(
        profileId: String,
        authData: Data,
        codexConfigURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clientName: String = "CodexProfileSwitcher",
        clientVersion: String) async throws -> UsageSnapshot
    {
        let executablePath = CodexCLIResolver.resolvePath(environment: environment)
        guard let executablePath else { throw CodexRPCError.cliNotFound }

        let tempHome = try self.makeTemporaryCodexHome(profileId: profileId)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        try AtomicFileWriter.write(authData, to: tempHome.appendingPathComponent("auth.json"))
        if FileManager.default.fileExists(atPath: codexConfigURL.path) {
            try? self.copyFile(from: codexConfigURL, to: tempHome.appendingPathComponent("config.toml"))
        }

        var env = environment
        env["CODEX_HOME"] = tempHome.path

        let rpc = try CodexRPCClient(executablePath: executablePath, environment: env)
        defer { rpc.shutdown() }

        try await rpc.initialize(clientName: clientName, clientVersion: clientVersion)
        let response = try await rpc.fetchRateLimits()
        return try self.makeSnapshot(from: response.rateLimits)
    }

    private static func makeTemporaryCodexHome(profileId: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-switcher-\(profileId)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return base
    }

    private static func copyFile(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        try AtomicFileWriter.write(data, to: destination)
    }

    private static func makeSnapshot(from rateLimits: RPCRateLimitSnapshot) throws -> UsageSnapshot {
        let creditsRemaining = rateLimits.credits.flatMap { credits -> Double? in
            guard let balance = credits.balance else { return nil }
            return Double(balance.replacingOccurrences(of: ",", with: ""))
        }

        let primaryResetAt = rateLimits.primary?.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let secondaryResetAt = rateLimits.secondary?.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let primaryUsedPercent = rateLimits.primary.map { Int($0.usedPercent.rounded()) } ?? 0
        let secondaryUsedPercent = rateLimits.secondary.map { Int($0.usedPercent.rounded()) } ?? 0

        if rateLimits.primary == nil, rateLimits.secondary == nil, creditsRemaining == nil {
            throw CLIUsageError.noRateLimitsFound
        }

        return UsageSnapshot(
            planType: rateLimits.planType,
            creditsRemaining: creditsRemaining,
            primaryUsedPercent: primaryUsedPercent,
            primaryResetAt: primaryResetAt,
            secondaryUsedPercent: secondaryUsedPercent,
            secondaryResetAt: secondaryResetAt,
            fetchedAt: Date())
    }
}
