import Foundation
import CodexProfileCore

// MARK: - Helpers

enum CodexBridgeError: LocalizedError {
    case cliNotFound
    case loginAlreadyRunning
    case loginCancelled
    case loginTimedOut
    case launchFailed(String)
    case commandFailed(Int32, String)
    case switchRolledBack(String)
    case switchCommittedButLaunchFailed(String)
    case stateUpdateFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "codex-profile helper not found"
        case .loginAlreadyRunning:
            return "Login is already running for this profile"
        case .loginCancelled:
            return "Login was cancelled"
        case .loginTimedOut:
            return "Login timed out. Start setup again to retry."
        case .launchFailed(let message):
            return message
        case .commandFailed(_, let output):
            return Self.helperFailureMessage(from: output)
        case .switchRolledBack(let message):
            return message
        case .switchCommittedButLaunchFailed(let message):
            return message
        case .stateUpdateFailed(let message):
            return message
        }
    }

    private static func helperFailureMessage(from output: String) -> String {
        guard !output.isEmpty else { return "codex-profile command failed" }

        let boilerplatePrefixes = [
            "Starting local login server",
            "If your browser did not open",
            "https://auth.openai.com/oauth/authorize",
            "On a remote or headless machine?",
            "Starting isolated login for profile ",
        ]
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let meaningful = lines.reversed().first(where: { line in
            line != "Successfully logged in" &&
                !boilerplatePrefixes.contains(where: line.hasPrefix)
        }) {
            if meaningful.hasPrefix("Error: ") {
                return String(meaningful.dropFirst("Error: ".count))
            }
            return meaningful
        }

        return LogRedactor.excerpt(output)
    }

    var isUserCancelled: Bool {
        if case .loginCancelled = self { return true }
        return false
    }
}

enum CodexBridge {
    private final class ActiveLogin {
        let process: Process
        let startedAt = Date()
        var cancelRequested = false
        var timedOut = false
        var timeoutWorkItem: DispatchWorkItem?

        init(process: Process) {
            self.process = process
        }
    }

    private static var activeLogins: [String: ActiveLogin] = [:]
    private static let staleLoginRetryInterval: TimeInterval = 5

    private static func pipeDrain(for pipe: Pipe) -> (start: @Sendable () -> Void, awaitOutput: @Sendable () -> String) {
        let group = DispatchGroup()
        nonisolated(unsafe) var captured = ""
        let start: @Sendable () -> Void = {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                captured = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                group.leave()
            }
        }
        let awaitOutput: @Sendable () -> String = {
            group.wait()
            return captured
        }
        return (start, awaitOutput)
    }

    private static func codexProfilePath() -> String? {
        let candidates: [String?] = [
            Bundle.main.bundleURL.pathExtension == "app"
                ? Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/codex-profile").path
                : nil,
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("codex-profile").path,
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("bin/codex-profile").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/codex-profile").path,
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    static func helperPathForDebug() -> String {
        self.codexProfilePath() ?? "<not found>"
    }

    /// Pin the delegated helper to the SAME auth backend the app uses. The app's
    /// backend follows the same signing-identity rule the helper would apply on
    /// its own; passing it explicitly removes the dependency on the app bundle
    /// and the resolved `codex-profile` binary sharing a signing identity, so a
    /// mismatch can't split auth across the Keychain and the file dev vault.
    private static func helperAuthEnvironment() -> [String: String] {
        if ProcessSigningIdentity.isStable {
            return ["CODEX_PROFILE_FORCE_KEYCHAIN": "1"]
        }
        return ["CODEX_PROFILE_FILE_AUTH_STORE_DIR": AppPaths().devAuthStoreURL.path]
    }

    static func isLoginRunning(profileId: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return Self.activeLogins[profileId] != nil
    }

    @discardableResult
    static func cancelLogin(profileId: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let active = Self.activeLogins[profileId] else { return false }
        active.cancelRequested = true
        active.timeoutWorkItem?.cancel()
        AppLogger.warning("Cancelling login", metadata: ["profile": profileId])
        active.process.terminate()
        return true
    }

    private static func runCommand(
        path: String,
        arguments: [String],
        completion: @escaping (Result<Void, CodexBridgeError>) -> Void
    ) {
        AppLogger.info("Running helper command",
                       metadata: ["path": path, "arguments": arguments.joined(separator: " ")])
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        proc.standardOutput = pipe
        proc.standardError = pipe

        let drain = self.pipeDrain(for: pipe)

        proc.terminationHandler = { p in
            let output = drain.awaitOutput()

            if p.terminationStatus == 0 {
                AppLogger.info("Helper command succeeded",
                               metadata: ["arguments": arguments.joined(separator: " ")])
                completion(.success(()))
            } else {
                AppLogger.error("Helper command failed",
                                metadata: [
                                    "arguments": arguments.joined(separator: " "),
                                    "status": "\(p.terminationStatus)",
                                    "output": output,
                                ])
                completion(.failure(.commandFailed(p.terminationStatus, output)))
            }
        }

        do {
            try proc.run()
            drain.start()
        } catch {
            AppLogger.error("Failed to launch helper command",
                            metadata: [
                                "path": path,
                                "arguments": arguments.joined(separator: " "),
                                "error": error.localizedDescription,
                            ])
            completion(.failure(.launchFailed(error.localizedDescription)))
        }
    }

    static func switchToProfile(
        _ profileId: String,
        workspacePath: String?,
        prepareTransaction: @escaping () throws -> PreparedProfileSwitch
    ) async -> Result<Void, CodexBridgeError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let transaction = try prepareTransaction()
                    if transaction.alreadyActive {
                        AppLogger.info("Profile switch skipped; profile is already active",
                                       metadata: ["profile": profileId])
                        continuation.resume(returning: .success(()))
                        return
                    }

                    try Self.quitCodexApp()
                    _ = try transaction.commit()
                    do {
                        try Self.launchCodexApp(workspacePath: workspacePath)
                    } catch let error as CodexBridgeError {
                        throw Self.committedLaunchFailure(error)
                    } catch {
                        throw Self.committedLaunchFailure(error)
                    }
                    AppLogger.info("Direct profile switch succeeded", metadata: ["profile": profileId])
                    continuation.resume(returning: .success(()))
                } catch let error as ProfileSwitchCommitError {
                    continuation.resume(returning: .failure(Self.bridgeError(from: error)))
                } catch let error as CodexBridgeError {
                    continuation.resume(returning: .failure(error))
                } catch {
                    AppLogger.error("Direct profile switch failed",
                                    metadata: ["profile": profileId, "error": error.localizedDescription])
                    continuation.resume(returning: .failure(.stateUpdateFailed(error.localizedDescription)))
                }
            }
        }
    }

    private static func bridgeError(from error: ProfileSwitchCommitError) -> CodexBridgeError {
        switch error.outcome {
        case .rolledBackAfterWriteFailure:
            return .switchRolledBack("Switch failed. Restored previous profile.")
        case .committedButLaunchFailed:
            return .switchCommittedButLaunchFailed(
                "Profile switched. Codex Desktop may need a manual restart.")
        case .committed:
            return .stateUpdateFailed(error.localizedDescription)
        }
    }

    private static func committedLaunchFailure(_ error: Error) -> CodexBridgeError {
        Self.bridgeError(from: ProfileSwitchCommitError(outcome: .committedButLaunchFailed(error)))
    }

    static func isCodexDesktopRunning() -> Bool {
        Self.runAndWait("/usr/bin/pgrep", arguments: ["-x", "Codex"], quiet: true) == 0
            || Self.runAndWait(
                "/usr/bin/pgrep",
                arguments: ["-f", "\(Self.codexBundledCLI()) app-server"],
                quiet: true
            ) == 0
    }

    private static func quitCodexApp() throws {
        guard Self.isCodexDesktopRunning() else { return }
        AppLogger.info("Quitting Codex before profile switch")
        _ = Self.runAndWait("/usr/bin/osascript", arguments: ["-e", "tell application \"Codex\" to quit"])

        let attempts = Int(Self.environment("CODEX_PROFILE_QUIT_ATTEMPTS") ?? "") ?? 10
        let sleepSeconds = Double(Self.environment("CODEX_PROFILE_QUIT_SLEEP") ?? "") ?? 0.5
        for _ in 0 ..< attempts {
            if !Self.isCodexDesktopRunning() { return }
            Thread.sleep(forTimeInterval: sleepSeconds)
        }

        AppLogger.warning("Codex still running after polite quit; sending SIGTERM")
        _ = Self.runAndWait("/usr/bin/pkill", arguments: ["-TERM", "-x", "Codex"], quiet: true)
        _ = Self.runAndWait(
            "/usr/bin/pkill",
            arguments: ["-TERM", "-f", "\(Self.codexBundledCLI()) app-server"],
            quiet: true)

        for _ in 0 ..< 10 {
            if !Self.isCodexDesktopRunning() { return }
            Thread.sleep(forTimeInterval: 0.5)
        }

        AppLogger.warning("Codex still running after SIGTERM; sending SIGKILL")
        _ = Self.runAndWait("/usr/bin/pkill", arguments: ["-KILL", "-x", "Codex"], quiet: true)
        _ = Self.runAndWait(
            "/usr/bin/pkill",
            arguments: ["-KILL", "-f", "\(Self.codexBundledCLI()) app-server"],
            quiet: true)

        for _ in 0 ..< 6 {
            if !Self.isCodexDesktopRunning() { return }
            Thread.sleep(forTimeInterval: 0.5)
        }

        throw CodexBridgeError.stateUpdateFailed(
            "Codex or its app-server is still running. Quit Codex with Cmd+Q, then retry.")
    }

    private static func launchCodexApp(workspacePath: String?) throws {
        let cli = Self.codexBundledCLI()
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            throw CodexBridgeError.launchFailed("Codex CLI not found at \(cli)")
        }
        let logDir = AppPaths().liveCodexHome.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: logDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let logFile = logDir.appendingPathComponent("desktop.log")
        FileManager.default.createFile(
            atPath: logFile.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["app"] + (workspacePath.map { [$0] } ?? [])
        let handle = try FileHandle(forWritingTo: logFile)
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
            try? handle.close()
        } catch {
            try? handle.close()
            throw CodexBridgeError.launchFailed(error.localizedDescription)
        }
    }

    private static func codexAppPath() -> String {
        Self.environment("CODEX_APP") ?? "/Applications/Codex.app"
    }

    private static func codexBundledCLI() -> String {
        "\(Self.codexAppPath())/Contents/Resources/codex"
    }

    private static func environment(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    @discardableResult
    private static func runAndWait(_ path: String, arguments: [String], quiet: Bool = false) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if quiet {
            process.standardOutput = Pipe()
            process.standardError = Pipe()
        }
        do {
            try process.run()
        } catch {
            AppLogger.error("Failed to launch process",
                            metadata: [
                                "path": path,
                                "arguments": arguments.joined(separator: " "),
                                "error": error.localizedDescription,
                            ])
            return 127
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func startLogin(
        profileId: String,
        completion: @escaping (Result<Void, CodexBridgeError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let active = Self.activeLogins[profileId] {
            let age = Date().timeIntervalSince(active.startedAt)
            guard age >= Self.staleLoginRetryInterval else {
                AppLogger.warning("Login already running", metadata: ["profile": profileId])
                completion(.failure(.loginAlreadyRunning))
                return
            }

            AppLogger.warning("Replacing stale login",
                              metadata: ["profile": profileId, "ageSeconds": "\(Int(age))"])
            active.cancelRequested = true
            active.timeoutWorkItem?.cancel()
            active.process.terminate()
            Self.activeLogins.removeValue(forKey: profileId)
        }
        guard let path = Self.codexProfilePath() else {
            AppLogger.error("codex-profile helper not found")
            completion(.failure(.cliNotFound))
            return
        }

        Self.runLoginCommand(path: path, profileId: profileId, completion: completion)
    }

    private static func runLoginCommand(
        path: String,
        profileId: String,
        completion: @escaping (Result<Void, CodexBridgeError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let arguments = ["login", profileId]
        AppLogger.info("Running helper command",
                       metadata: ["path": path, "arguments": arguments.joined(separator: " ")])

        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        proc.standardOutput = pipe
        proc.standardError = pipe

        var childEnv = ProcessInfo.processInfo.environment
        for (key, value) in Self.helperAuthEnvironment() {
            childEnv[key] = value
        }
        proc.environment = childEnv

        let active = ActiveLogin(process: proc)
        Self.activeLogins[profileId] = active

        let drain = self.pipeDrain(for: pipe)

        proc.terminationHandler = { p in
            let output = drain.awaitOutput()

            DispatchQueue.main.async {
                active.timeoutWorkItem?.cancel()
                if Self.activeLogins[profileId] === active {
                    Self.activeLogins.removeValue(forKey: profileId)
                }

                if active.timedOut {
                    AppLogger.error("Helper login timed out",
                                    metadata: ["arguments": arguments.joined(separator: " ")])
                    completion(.failure(.loginTimedOut))
                    return
                }

                if active.cancelRequested {
                    AppLogger.warning("Helper login cancelled",
                                      metadata: ["arguments": arguments.joined(separator: " ")])
                    completion(.failure(.loginCancelled))
                    return
                }

                if p.terminationStatus == 0 {
                    AppLogger.info("Helper command succeeded",
                                   metadata: ["arguments": arguments.joined(separator: " ")])
                    completion(.success(()))
                } else {
                    AppLogger.error("Helper command failed",
                                    metadata: [
                                        "arguments": arguments.joined(separator: " "),
                                        "status": "\(p.terminationStatus)",
                                        "output": output,
                                    ])
                    completion(.failure(.commandFailed(p.terminationStatus, output)))
                }
            }
        }

        do {
            try proc.run()
            drain.start()
            let timeout = Self.loginTimeoutSeconds()
            let timeoutWorkItem = DispatchWorkItem {
                DispatchQueue.main.async {
                    guard Self.activeLogins[profileId] === active else { return }
                    active.timedOut = true
                    AppLogger.warning("Terminating timed-out login",
                                      metadata: ["profile": profileId, "timeoutSeconds": "\(Int(timeout))"])
                    active.process.terminate()
                }
            }
            active.timeoutWorkItem = timeoutWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
        } catch {
            Self.activeLogins.removeValue(forKey: profileId)
            AppLogger.error("Failed to launch helper command",
                            metadata: [
                                "path": path,
                                "arguments": arguments.joined(separator: " "),
                                "error": error.localizedDescription,
                            ])
            completion(.failure(.launchFailed(error.localizedDescription)))
        }
    }

    private static func loginTimeoutSeconds() -> TimeInterval {
        let raw = ProcessInfo.processInfo.environment["CODEX_PROFILE_LOGIN_TIMEOUT_SECONDS"] ?? ""
        guard let value = Double(raw), value > 0 else { return 15 * 60 }
        return value
    }
}
