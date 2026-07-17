import Darwin
import Foundation

public struct CodexDesktopInstallation {
    public let appPath: String?
    public let bundleIdentifier: String
    public let executablePath: String?
    public let bundledCLIPath: String

    public init(appPath: String?, bundleIdentifier: String, executablePath: String?, bundledCLIPath: String) {
        self.appPath = appPath
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.bundledCLIPath = bundledCLIPath
    }
}

public enum CodexDesktopLifecycleError: LocalizedError {
    case installationNotFound
    case invalidInstallation(String)
    case bundledCLINotFound(String)
    case shutdownFailed
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .installationNotFound:
            return "Codex Desktop installation not found. Install ChatGPT or set CODEX_APP."
        case .invalidInstallation(let path):
            return "Invalid Codex Desktop installation at " + path
        case .bundledCLINotFound(let path):
            return "Codex CLI not found at " + path
        case .shutdownFailed:
            return "Codex Desktop is still running after shutdown attempts"
        case .launchFailed(let message):
            return "Codex Desktop launch failed: " + message
        }
    }
}

public struct CodexDesktopLifecycle {
    public static let bundleIdentifier = "com.openai.codex"
    private let environment: [String: String]
    private let fileManager: FileManager

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
    }

    public func resolveInstallation() throws -> CodexDesktopInstallation {
        let appOverride = self.value("CODEX_PROFILE_TEST_APP") ?? self.value("CODEX_APP")
        if let appOverride {
            return try self.installation(at: appOverride)
        }

        if let bundledOverride = self.value("CODEX_PROFILE_TEST_BUNDLED_CLI")
            ?? self.value("CODEX_BUNDLED_CLI") {
            return CodexDesktopInstallation(
                appPath: nil,
                bundleIdentifier: Self.bundleIdentifier,
                executablePath: nil,
                bundledCLIPath: bundledOverride)
        }

        for candidate in self.discoveredAppPaths() {
            if let installation = try? self.installation(at: candidate) {
                return installation
            }
        }
        throw CodexDesktopLifecycleError.installationNotFound
    }

    public func resolveBundledCLI() throws -> String {
        if let override = self.value("CODEX_PROFILE_TEST_BUNDLED_CLI")
            ?? self.value("CODEX_BUNDLED_CLI") {
            guard self.fileManager.isExecutableFile(atPath: override) else {
                throw CodexDesktopLifecycleError.bundledCLINotFound(override)
            }
            return override
        }
        let installation = try self.resolveInstallation()
        guard self.fileManager.isExecutableFile(atPath: installation.bundledCLIPath) else {
            throw CodexDesktopLifecycleError.bundledCLINotFound(installation.bundledCLIPath)
        }
        return installation.bundledCLIPath
    }

    public func isDesktopRunning() -> Bool {
        if self.value("CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED") == "1" { return false }
        if let pidFile = self.value("CODEX_PROFILE_TEST_DESKTOP_PID_FILE"),
           let pid = self.readPID(from: pidFile),
           pid > 0 {
            return kill(pid, 0) == 0
        }
        guard let installation = try? self.resolveInstallation() else { return false }
        if let executable = installation.executablePath,
           self.runAndWait("/usr/bin/pgrep", arguments: ["-f", executable], quiet: true) == 0 {
            return true
        }
        return self.runAndWait(
            "/usr/bin/pgrep",
            arguments: ["-f", installation.bundledCLIPath + " app-server"],
            quiet: true) == 0
    }

    public func stopDesktop() throws {
        guard self.isDesktopRunning() else { return }
        self.requestNormalQuit()
        if self.waitUntilStopped() { return }
        self.terminateDesktop(signal: SIGTERM)
        if self.waitUntilStopped() { return }
        self.terminateDesktop(signal: SIGKILL)
        guard self.waitUntilStopped() else { throw CodexDesktopLifecycleError.shutdownFailed }
    }

    public func launch(workspacePath: String?, logURL: URL? = nil) throws {
        let cli = try self.resolveBundledCLI()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["app"] + (workspacePath.map { [$0] } ?? [])
        var handle: FileHandle?
        if let logURL {
            self.fileManager.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            handle = try FileHandle(forWritingTo: logURL)
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
            try? handle?.close()
        } catch {
            try? handle?.close()
            throw CodexDesktopLifecycleError.launchFailed(error.localizedDescription)
        }
        if self.value("CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED") == "1" {
            return
        }
        guard self.waitUntilRunning() else {
            let status = process.isRunning ? "did not start" : "exited with status " + String(process.terminationStatus)
            throw CodexDesktopLifecycleError.launchFailed(status)
        }
    }

    private func installation(at appPath: String) throws -> CodexDesktopInstallation {
        let infoURL = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard self.fileManager.fileExists(atPath: infoURL.path),
              let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              info["CFBundleIdentifier"] as? String == Self.bundleIdentifier,
              let executableName = info["CFBundleExecutable"] as? String,
              !executableName.isEmpty else {
            throw CodexDesktopLifecycleError.invalidInstallation(appPath)
        }
        let executable = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(executableName).path
        let bundledCLI = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/Resources/codex").path
        guard self.fileManager.isExecutableFile(atPath: executable) else {
            throw CodexDesktopLifecycleError.invalidInstallation(appPath)
        }
        return CodexDesktopInstallation(
            appPath: appPath,
            bundleIdentifier: Self.bundleIdentifier,
            executablePath: executable,
            bundledCLIPath: bundledCLI)
    }

    private func discoveredAppPaths() -> [String] {
        let roots = ["/Applications", self.fileManager.homeDirectoryForCurrentUser.path + "/Applications"]
        return roots.flatMap { root in
            (try? self.fileManager.contentsOfDirectory(atPath: root))?.filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: root).appendingPathComponent($0).path } ?? []
        }
    }

    private func requestNormalQuit() {
        if let pidFile = self.value("CODEX_PROFILE_TEST_DESKTOP_PID_FILE"),
           let pid = self.readPID(from: pidFile),
           pid > 0 {
            _ = kill(pid, SIGTERM)
            return
        }
        if self.value("CODEX_PROFILE_HOME") != nil
            || self.value("CODEX_PROFILE_TEST_AUTH_STORE_DIR") != nil {
            return
        }
        _ = self.runAndWait(
            "/usr/bin/osascript",
            arguments: ["-e", "tell application id \"" + Self.bundleIdentifier + "\" to quit"],
            quiet: true)
    }

    private func terminateDesktop(signal: Int32) {
        guard let installation = try? self.resolveInstallation() else { return }
        if let executable = installation.executablePath {
            _ = self.runAndWait("/usr/bin/pkill", arguments: ["-\(signal == SIGKILL ? "KILL" : "TERM")", "-f", executable], quiet: true)
        }
        _ = self.runAndWait(
            "/usr/bin/pkill",
            arguments: ["-\(signal == SIGKILL ? "KILL" : "TERM")", "-f", installation.bundledCLIPath + " app-server"],
            quiet: true)
    }

    private func waitUntilStopped() -> Bool {
        let attempts = Int(self.value("CODEX_PROFILE_QUIT_ATTEMPTS") ?? "10") ?? 10
        let sleepSeconds = Double(self.value("CODEX_PROFILE_QUIT_SLEEP") ?? "0.5") ?? 0.5
        for _ in 0 ..< attempts {
            if !self.isDesktopRunning() { return true }
            Thread.sleep(forTimeInterval: sleepSeconds)
        }
        return !self.isDesktopRunning()
    }

    private func waitUntilRunning() -> Bool {
        for _ in 0 ..< 40 {
            if self.isDesktopRunning() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return self.isDesktopRunning()
    }

    private func value(_ key: String) -> String? {
        let value = self.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func readPID(from path: String) -> Int32? {
        guard let text = try? String(contentsOfFile: path),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            return nil
        }
        return pid
    }

    @discardableResult
    private func runAndWait(_ path: String, arguments: [String], quiet: Bool = false) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if quiet {
            process.standardOutput = Pipe()
            process.standardError = Pipe()
        }
        guard (try? process.run()) != nil else { return 127 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
