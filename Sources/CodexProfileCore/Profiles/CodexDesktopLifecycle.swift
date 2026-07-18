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
    case launchTargetMismatch(String, String)
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
        case .launchTargetMismatch(let appPath, let cliPath):
            return "CODEX_APP and CODEX_BUNDLED_CLI must belong to the same Codex Desktop installation (app: "
                + appPath + ", CLI: " + cliPath + ")"
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
            let installation = try self.installation(at: appOverride)
            guard self.isAllowedTestInstallation(installation) else {
                throw CodexDesktopLifecycleError.invalidInstallation(appOverride)
            }
            return installation
        }
        guard let installation = self.resolveInstallations().first else {
            throw CodexDesktopLifecycleError.installationNotFound
        }
        return installation
    }

    public func resolveBundledCLI() throws -> String {
        try self.resolveLaunchTarget().bundledCLIPath
    }

    public func isDesktopRunning() -> Bool {
        if self.value("CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED") == "1" { return false }
        let installations = self.resolveInstallations()
        if let pidFile = self.value("CODEX_PROFILE_TEST_DESKTOP_PID_FILE"),
           let pid = self.readPID(from: pidFile),
           installations.contains(where: { self.process(pid, belongsTo: $0, includeBundledCLI: false) }) {
            return true
        }
        return !self.ownedPIDs(for: installations, includeBundledCLI: false).isEmpty
    }

    public func stopDesktop() throws {
        if self.value("CODEX_PROFILE_TEST_DESKTOP_PID_FILE") != nil {
            _ = try self.validatedTestPID()
        }
        guard self.ownedProcessIsRunning() else { return }
        try self.requestNormalQuit()
        if self.waitUntilStopped() { return }
        self.terminateDesktop(signal: SIGTERM)
        if self.waitUntilStopped() { return }
        self.terminateDesktop(signal: SIGKILL)
        guard self.waitUntilStopped() else { throw CodexDesktopLifecycleError.shutdownFailed }
    }

    public func launch(workspacePath: String?, logURL: URL? = nil) throws {
        let target = try self.resolveLaunchTarget()
        let cli = target.bundledCLIPath
        let installation = target.installation
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
        guard let installation,
              let failure = self.waitUntilRunning(for: installation, launcher: process) else {
            return
        }
        throw CodexDesktopLifecycleError.launchFailed(failure)
    }

    private struct LaunchTarget {
        let installation: CodexDesktopInstallation?
        let bundledCLIPath: String
    }

    private func resolveLaunchTarget() throws -> LaunchTarget {
        let appOverride = self.value("CODEX_PROFILE_TEST_APP") ?? self.value("CODEX_APP")
        let cliOverride = self.value("CODEX_PROFILE_TEST_BUNDLED_CLI")
            ?? self.value("CODEX_BUNDLED_CLI")
        if let appOverride {
            let installation = try self.validatedInstallation(at: appOverride)
            let cli = self.canonicalPath(cliOverride ?? installation.bundledCLIPath)
            try self.validateBundledCLI(cli)
            guard cli == installation.bundledCLIPath else {
                throw CodexDesktopLifecycleError.launchTargetMismatch(appOverride, cli)
            }
            return LaunchTarget(installation: installation, bundledCLIPath: cli)
        }
        if let cliOverride {
            let canonicalCLI = self.canonicalPath(cliOverride)
            try self.validateBundledCLI(canonicalCLI)
            if self.value("CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED") == "1" {
                return LaunchTarget(installation: nil, bundledCLIPath: canonicalCLI)
            }
            let appPath = URL(fileURLWithPath: canonicalCLI)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent().path
            let installation = try self.validatedInstallation(at: appPath)
            guard canonicalCLI == installation.bundledCLIPath else {
                throw CodexDesktopLifecycleError.launchTargetMismatch(appPath, canonicalCLI)
            }
            return LaunchTarget(installation: installation, bundledCLIPath: canonicalCLI)
        }
        let installation = try self.resolveInstallation()
        let canonicalCLI = self.canonicalPath(installation.bundledCLIPath)
        try self.validateBundledCLI(canonicalCLI)
        guard canonicalCLI == installation.bundledCLIPath else {
            throw CodexDesktopLifecycleError.launchTargetMismatch(
                installation.appPath ?? "", canonicalCLI)
        }
        return LaunchTarget(installation: installation, bundledCLIPath: canonicalCLI)
    }

    private func validatedInstallation(at appPath: String) throws -> CodexDesktopInstallation {
        let installation = try self.installation(at: appPath)
        guard self.isAllowedTestInstallation(installation) else {
            throw CodexDesktopLifecycleError.invalidInstallation(appPath)
        }
        return installation
    }

    private func validateBundledCLI(_ path: String) throws {
        guard self.fileManager.isExecutableFile(atPath: path) else {
            throw CodexDesktopLifecycleError.bundledCLINotFound(path)
        }
    }

    private func installation(at appPath: String) throws -> CodexDesktopInstallation {
        let canonicalAppPath = self.canonicalPath(appPath)
        let appURL = URL(fileURLWithPath: canonicalAppPath)
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard self.fileManager.fileExists(atPath: infoURL.path),
              let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              info["CFBundleIdentifier"] as? String == Self.bundleIdentifier,
              let executableName = info["CFBundleExecutable"] as? String,
              !executableName.isEmpty else {
            throw CodexDesktopLifecycleError.invalidInstallation(appPath)
        }
        let executable = appURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(executableName).path
        let bundledCLI = appURL
            .appendingPathComponent("Contents/Resources/codex").path
        guard self.fileManager.isExecutableFile(atPath: executable) else {
            throw CodexDesktopLifecycleError.invalidInstallation(appPath)
        }
        return CodexDesktopInstallation(
            appPath: canonicalAppPath,
            bundleIdentifier: Self.bundleIdentifier,
            executablePath: self.canonicalPath(executable),
            bundledCLIPath: bundledCLI)
    }

    private func resolveInstallations() -> [CodexDesktopInstallation] {
        if self.isolatedTestMode && self.isolatedTestApplicationsRoot() == nil {
            return []
        }
        let discovered = self.discoveredAppPaths().compactMap { try? self.installation(at: $0) }
        guard let appOverride = self.value("CODEX_PROFILE_TEST_APP") ?? self.value("CODEX_APP"),
              let explicit = try? self.installation(at: appOverride),
              self.isAllowedTestInstallation(explicit) else {
            return discovered
        }
        let explicitPath = self.canonicalPath(explicit.appPath ?? "")
        return [explicit] + discovered.filter {
            self.canonicalPath($0.appPath ?? "") != explicitPath
        }
    }

    private func discoveredAppPaths() -> [String] {
        let roots: [String]
        if self.isolatedTestMode {
            guard let isolatedRoot = self.isolatedTestApplicationsRoot() else { return [] }
            roots = [isolatedRoot]
        } else {
            roots = ["/Applications", self.fileManager.homeDirectoryForCurrentUser.path + "/Applications"]
        }
        return roots.flatMap { root in
            (try? self.fileManager.contentsOfDirectory(atPath: root))?.filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: root).appendingPathComponent($0).path } ?? []
        }.sorted { lhs, rhs in
            let lhsIsCurrent = URL(fileURLWithPath: lhs).lastPathComponent == "ChatGPT.app"
            let rhsIsCurrent = URL(fileURLWithPath: rhs).lastPathComponent == "ChatGPT.app"
            if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            return self.canonicalPath(lhs) < self.canonicalPath(rhs)
        }
    }

    private var isolatedTestMode: Bool {
        self.value("CODEX_PROFILE_TEST_AUTH_STORE_DIR") != nil
            || self.value("CODEX_PROFILE_TEST_DESKTOP_PID_FILE") != nil
            || self.value("CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED") == "1"
    }

    private func isolatedTestApplicationsRoot() -> String? {
        guard let root = self.value("CODEX_PROFILE_TEST_APPLICATIONS_DIR"),
              self.fileManager.fileExists(atPath: root),
              (try? self.fileManager.contentsOfDirectory(atPath: root)) != nil else {
            return nil
        }
        return self.canonicalPath(root)
    }

    private func isAllowedTestInstallation(_ installation: CodexDesktopInstallation) -> Bool {
        guard self.isolatedTestMode else { return true }
        guard let root = self.isolatedTestApplicationsRoot(),
              let appPath = installation.appPath else { return false }
        let canonicalRoot = self.canonicalPath(root)
        let canonicalApp = self.canonicalPath(appPath)
        return canonicalApp == canonicalRoot
            || canonicalApp.hasPrefix(canonicalRoot + "/")
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
            var pids = Set([pid])
            pids.formUnion(self.ownedPIDs(for: self.resolveInstallations(), includeBundledCLI: true))
            for ownedPID in pids {
                _ = kill(ownedPID, signal)
            }
            return
        }
        for pid in self.ownedPIDs(for: self.resolveInstallations(), includeBundledCLI: true) {
            _ = kill(pid, signal)
        }
    }

    private func waitUntilStopped() -> Bool {
        let attempts = Int(self.value("CODEX_PROFILE_QUIT_ATTEMPTS") ?? "10") ?? 10
        let sleepSeconds = Double(self.value("CODEX_PROFILE_QUIT_SLEEP") ?? "0.5") ?? 0.5
        for _ in 0 ..< attempts {
            if !self.ownedProcessIsRunning() { return true }
            Thread.sleep(forTimeInterval: sleepSeconds)
        }
        return !self.ownedProcessIsRunning()
    }

    private func waitUntilRunning(
        for installation: CodexDesktopInstallation,
        launcher: Process
    ) -> String? {
        let attempts = max(Int(self.value("CODEX_PROFILE_LAUNCH_ATTEMPTS") ?? "120") ?? 120, 1)
        let sleepSeconds = max(Double(self.value("CODEX_PROFILE_LAUNCH_SLEEP") ?? "1") ?? 1, 0.01)
        for _ in 0 ..< attempts {
            if self.isDesktopRunning(for: installation) { return nil }
            guard launcher.isRunning else { break }
            Thread.sleep(forTimeInterval: sleepSeconds)
        }
        if self.isDesktopRunning(for: installation) { return nil }
        guard !launcher.isRunning else {
            return "did not start within " + String(Int(Double(attempts) * sleepSeconds)) + " seconds"
        }
        guard launcher.terminationStatus == 0 else {
            return "exited with status " + String(launcher.terminationStatus)
        }
        let handoffAttempts = max(Int(self.value("CODEX_PROFILE_LAUNCH_HANDOFF_ATTEMPTS") ?? "10") ?? 10, 1)
        let handoffSleep = max(Double(self.value("CODEX_PROFILE_LAUNCH_HANDOFF_SLEEP") ?? "0.5") ?? 0.5, 0.01)
        for _ in 0 ..< handoffAttempts {
            if self.isDesktopRunning(for: installation) { return nil }
            Thread.sleep(forTimeInterval: handoffSleep)
        }
        return "exited successfully but GUI did not start"
    }

    private func isDesktopRunning(for installation: CodexDesktopInstallation) -> Bool {
        if let pidFile = self.value("CODEX_PROFILE_TEST_DESKTOP_PID_FILE"),
           let pid = self.readPID(from: pidFile),
           self.process(pid, belongsTo: installation, includeBundledCLI: false) {
            return true
        }
        return !self.ownedPIDs(for: [installation], includeBundledCLI: false).isEmpty
    }

    private func ownedProcessIsRunning() -> Bool {
        if self.value("CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED") == "1" { return false }
        let installations = self.resolveInstallations()
        if let pidFile = self.value("CODEX_PROFILE_TEST_DESKTOP_PID_FILE"),
           let pid = self.readPID(from: pidFile),
           installations.contains(where: { self.process(pid, belongsTo: $0, includeBundledCLI: true) }) {
            return true
        }
        return !self.ownedPIDs(for: installations, includeBundledCLI: true).isEmpty
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
              self.resolveInstallations().contains(where: {
                  self.process(pid, belongsTo: $0, includeBundledCLI: true)
              }) else {
            throw CodexDesktopLifecycleError.unsafeTestBoundary
        }
        return pid
    }

    private func ownedPIDs(
        for installations: [CodexDesktopInstallation],
        includeBundledCLI: Bool
    ) -> [Int32] {
        let rows = self.runAndRead("/bin/ps", arguments: ["-axo", "pid="])
        return rows.split(whereSeparator: \.isNewline).compactMap { row in
            guard let pid = Int32(row.trimmingCharacters(in: .whitespaces)) else { return nil }
            return installations.contains {
                self.process(pid, belongsTo: $0, includeBundledCLI: includeBundledCLI)
            } ? pid : nil
        }
    }

    private func process(
        _ pid: Int32,
        belongsTo installation: CodexDesktopInstallation,
        includeBundledCLI: Bool
    ) -> Bool {
        guard let identity = self.processIdentity(pid) else { return false }
        if let executable = installation.executablePath,
           self.canonicalPath(identity.executablePath) == self.canonicalPath(executable) {
            return true
        }
        if self.value("CODEX_PROFILE_TEST_DESKTOP_PID_FILE") != nil,
           let executable = installation.executablePath,
           identity.arguments.contains(where: { self.canonicalPath($0) == self.canonicalPath(executable) }) {
            return true
        }
        guard includeBundledCLI,
              self.canonicalPath(identity.executablePath) == self.canonicalPath(installation.bundledCLIPath) else {
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
        guard data.count >= MemoryLayout<Int32>.size else { return [] }
        let argc = data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(as: Int32.self)
        }
        guard argc >= 0 else { return [] }
        let fields = data.dropFirst(MemoryLayout<Int32>.size).split(separator: 0)
        guard fields.count >= Int(argc) + 1 else { return [] }
        return fields.dropFirst().prefix(Int(argc)).compactMap {
            String(bytes: $0, encoding: .utf8)
        }
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
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
