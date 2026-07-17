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
    case unsafeTestBoundary
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
        case .unsafeTestBoundary:
            return "Refusing desktop shutdown without a fake test PID boundary"
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
        guard let installation = self.resolveInstallations().first else {
            throw CodexDesktopLifecycleError.installationNotFound
        }
        return installation
    }

    public func resolveBundledCLI() throws -> String {
        if let appOverride = self.value("CODEX_PROFILE_TEST_APP") ?? self.value("CODEX_APP") {
            _ = try self.installation(at: appOverride)
        }
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
        let installations = self.resolveInstallations()
        if let pidFile = self.value("CODEX_PROFILE_TEST_DESKTOP_PID_FILE"),
           let pid = self.readPID(from: pidFile),
           installations.contains(where: { self.process(pid, belongsTo: $0) }) {
            return true
        }
        return !self.ownedPIDs(for: installations).isEmpty
    }

    public func stopDesktop() throws {
        if self.value("CODEX_PROFILE_TEST_DESKTOP_PID_FILE") != nil {
            _ = try self.validatedTestPID()
        }
        guard self.isDesktopRunning() else { return }
        try self.requestNormalQuit()
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

    private func resolveInstallations() -> [CodexDesktopInstallation] {
        let discovered = self.discoveredAppPaths().compactMap { try? self.installation(at: $0) }
        guard let appOverride = self.value("CODEX_PROFILE_TEST_APP") ?? self.value("CODEX_APP"),
              let explicit = try? self.installation(at: appOverride) else {
            return discovered
        }
        let explicitPath = self.normalizePath(explicit.appPath ?? "")
        return [explicit] + discovered.filter {
            self.normalizePath($0.appPath ?? "") != explicitPath
        }
    }

    private func discoveredAppPaths() -> [String] {
        let roots: [String]
        let isolatedMode = self.value("CODEX_PROFILE_TEST_AUTH_STORE_DIR") != nil
            || self.value("CODEX_PROFILE_TEST_DESKTOP_PID_FILE") != nil
            || self.value("CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED") == "1"
        if isolatedMode {
            guard let isolatedRoot = self.value("CODEX_PROFILE_TEST_APPLICATIONS_DIR"),
                  self.fileManager.fileExists(atPath: isolatedRoot),
                  (try? self.fileManager.contentsOfDirectory(atPath: isolatedRoot)) != nil else {
                return []
            }
            roots = [isolatedRoot]
        } else {
            roots = ["/Applications", self.fileManager.homeDirectoryForCurrentUser.path + "/Applications"]
        }
        return roots.flatMap { root in
            (try? self.fileManager.contentsOfDirectory(atPath: root))?.filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: root).appendingPathComponent($0).path } ?? []
        }
    }

    private func requestNormalQuit() throws {
        if self.value("CODEX_PROFILE_TEST_DESKTOP_PID_FILE") != nil {
            let pid = try self.validatedTestPID()
            _ = kill(pid, SIGTERM)
            return
        }
        if self.value("CODEX_PROFILE_TEST_AUTH_STORE_DIR") != nil
            || self.value("CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED") == "1" {
            throw CodexDesktopLifecycleError.unsafeTestBoundary
        }
        _ = self.runAndWait(
            "/usr/bin/osascript",
            arguments: ["-e", "tell application id \"" + Self.bundleIdentifier + "\" to quit"],
            quiet: true)
    }

    private func terminateDesktop(signal: Int32) {
        if self.value("CODEX_PROFILE_TEST_DESKTOP_PID_FILE") != nil {
            guard let pid = try? self.validatedTestPID() else { return }
            _ = kill(pid, signal)
            return
        }
        for pid in self.ownedPIDs(for: self.resolveInstallations()) {
            _ = kill(pid, signal)
        }
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

    private func validatedTestPID() throws -> Int32 {
        guard let pidFile = self.value("CODEX_PROFILE_TEST_DESKTOP_PID_FILE"),
              let pid = self.readPID(from: pidFile),
              self.resolveInstallations().contains(where: { self.process(pid, belongsTo: $0) }) else {
            throw CodexDesktopLifecycleError.unsafeTestBoundary
        }
        return pid
    }

    private func ownedPIDs(for installations: [CodexDesktopInstallation]) -> [Int32] {
        let rows = self.runAndRead("/bin/ps", arguments: ["-axo", "pid="])
        return rows.split(whereSeparator: \.isNewline).compactMap { row in
            guard let pid = Int32(row.trimmingCharacters(in: .whitespaces)) else { return nil }
            return installations.contains { self.process(pid, belongsTo: $0) } ? pid : nil
        }
    }

    private func process(_ pid: Int32, belongsTo installation: CodexDesktopInstallation) -> Bool {
        guard let identity = self.processIdentity(pid) else { return false }
        if let executable = installation.executablePath,
           self.normalizePath(identity.executablePath) == self.normalizePath(executable) {
            return true
        }
        if self.value("CODEX_PROFILE_TEST_DESKTOP_PID_FILE") != nil,
           let executable = installation.executablePath,
           identity.arguments.contains(where: { self.normalizePath($0) == self.normalizePath(executable) }) {
            return true
        }
        guard self.normalizePath(identity.executablePath) == self.normalizePath(installation.bundledCLIPath) else {
            return false
        }
        return identity.arguments.contains("app-server")
    }

    private struct ProcessIdentity {
        let executablePath: String
        let arguments: [String]
    }

    private func processIdentity(_ pid: Int32) -> ProcessIdentity? {
        var buffer = [Int8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let executable = String(cString: buffer)
        return ProcessIdentity(executablePath: executable, arguments: self.processArguments(pid))
    }

    private func processArguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { return [] }
        return data.dropFirst(4).split(separator: 0).compactMap {
            String(bytes: $0, encoding: .utf8)
        }
    }

    private func normalizePath(_ path: String) -> String {
        var normalized = path
        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }
        if normalized.hasPrefix("/private/") {
            normalized = String(normalized.dropFirst("/private".count))
        }
        return normalized
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

    private func runAndRead(_ path: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
