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
        if Bundle.main.bundleURL.pathExtension == "app" {
            let bundledHelper = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/codex-profile").path
            return FileManager.default.isExecutableFile(atPath: bundledHelper) ? bundledHelper : nil
        }

        let candidates: [String?] = [
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
    static func helperAuthEnvironment(for environment: [String: String]) -> [String: String] {
        if let override = Self.profileHomeOverride(in: environment),
           Self.canonicalURL(override) != Self.canonicalURL(
               FileManager.default.homeDirectoryForCurrentUser) {
            return [
                "CODEX_PROFILE_FILE_AUTH_STORE_DIR":
                    AppPaths(environment: environment).devAuthStoreURL.path,
            ]
        }
        if ProcessSigningIdentity.isStable {
            return ["CODEX_PROFILE_FORCE_KEYCHAIN": "1"]
        }
        return ["CODEX_PROFILE_FILE_AUTH_STORE_DIR": AppPaths(environment: environment).devAuthStoreURL.path]
    }

    static func helperProcessEnvironment(for environment: [String: String]) -> [String: String] {
        let backendSelectors = [
            "CODEX_PROFILE_TEST_AUTH_STORE_DIR",
            "CODEX_PROFILE_FILE_AUTH_STORE_DIR",
            "CODEX_PROFILE_FORCE_KEYCHAIN",
        ]
        var childEnvironment = environment
        for key in backendSelectors {
            childEnvironment.removeValue(forKey: key)
        }
        for (key, value) in Self.helperAuthEnvironment(for: environment) {
            childEnvironment[key] = value
        }
        return childEnvironment
    }

    private static func profileHomeOverride(in environment: [String: String]) -> URL? {
        for key in ["CODEX_PROFILE_HOME", "CODEX_PROFILE_TEST_HOME"] {
            if let path = environment[key], !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
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
                    let lifecycle = CodexDesktopLifecycle()
                    _ = try lifecycle.resolveBundledCLI()
                    let initialTransaction = try prepareTransaction()
                    if initialTransaction.alreadyActive {
                        AppLogger.info("Profile switch skipped; profile is already active",
                                       metadata: ["profile": profileId])
                        continuation.resume(returning: .success(()))
                        return
                    }

                    try lifecycle.stopDesktop()
                    let transaction = try prepareTransaction()
                    _ = try transaction.commit()
                    do {
                        let logDir = AppPaths().liveCodexHome.appendingPathComponent("logs", isDirectory: true)
                        try FileManager.default.createDirectory(
                            at: logDir,
                            withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o700])
                        try lifecycle.launch(
                            workspacePath: workspacePath,
                            logURL: logDir.appendingPathComponent("desktop.log"))
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
        case .committedButLaunchFailed(let error):
            return .switchCommittedButLaunchFailed(
                "Profile switched, but Codex Desktop could not be relaunched: \(error.localizedDescription)")
        case .committed:
            return .stateUpdateFailed(error.localizedDescription)
        }
    }

    private static func committedLaunchFailure(_ error: Error) -> CodexBridgeError {
        Self.bridgeError(from: ProfileSwitchCommitError(outcome: .committedButLaunchFailed(error)))
    }

    static func isCodexDesktopRunning() -> Bool {
        CodexDesktopLifecycle().isDesktopRunning()
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

        proc.environment = Self.helperProcessEnvironment(for: ProcessInfo.processInfo.environment)

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
