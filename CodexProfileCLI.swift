import CryptoKit
import Foundation

private enum CLIError: LocalizedError {
    case message(String)
    case exitStatus(Int32)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .exitStatus(let status): return "codex login exited with status \(status)"
        }
    }
}

private struct CLIConfig: Codable {
    var profiles: [CLIProfileConfig]
    var activeProfile: String
    var authStorageVersion: Int?
}

private struct CLIProfileConfig: Codable {
    var id: String
    var label: String
}

@main
enum CodexProfileCLI {
    private static let program = URL(fileURLWithPath: CommandLine.arguments.first ?? "codex-profile").lastPathComponent
    private static let fileManager = FileManager.default
    private static let keychainService = Self.environment("CODEX_PROFILE_KEYCHAIN_SERVICE")
        ?? KeychainAuthVault.defaultService
    private static let vault = Self.makeVault()
    private static let storageVersion = 2

    static func main() {
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            let command = args.isEmpty ? "help" : args.removeFirst()
            switch command {
            case "app": try self.commandApp(args)
            case "login": try self.commandLogin(args)
            case "status": try self.commandStatus(args)
            case "list": try self.commandList()
            case "path": try self.commandPath(args)
            case "doctor": try self.commandDoctor()
            case "help", "-h", "--help": self.usage()
            default: throw CLIError.message("Unknown command '\(command)'. See \(self.program) help.")
            }
        } catch CLIError.exitStatus(let status) {
            exit(status)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func usage() {
        print("""
        \(self.program) - manage Codex auth profiles with a shared live ~/.codex runtime

        Usage:
          \(self.program) app <profile> [workspace]
          \(self.program) login <profile> [codex-login-args...]
          \(self.program) status [profile]
          \(self.program) list
          \(self.program) path <profile>
          \(self.program) doctor
        """)
    }

    private static func commandLogin(_ args: [String]) throws {
        guard let profile = args.first else {
            throw CLIError.message("Usage: \(self.program) login <profile> [codex-login-args...]")
        }
        try self.validateProfile(profile)

        let tempHome = try self.makeTempHome(profile: profile)
        defer { try? self.fileManager.removeItem(at: tempHome) }

        let codexCLI = try self.findCodexCLI()
        self.note("Starting isolated login for profile '\(profile)'...")
        let status = self.runAndWait(
            codexCLI,
            arguments: ["login"] + Array(args.dropFirst()),
            environment: ["CODEX_HOME": tempHome.path])
        guard status == 0 else { throw CLIError.exitStatus(status) }

        let authURL = tempHome.appendingPathComponent("auth.json")
        guard self.fileManager.fileExists(atPath: authURL.path) else {
            throw CLIError.message("Login completed but no auth.json was created")
        }
        let data = try Data(contentsOf: authURL)
        guard AuthBlob.isPlausibleAuthBlob(data) else {
            throw CLIError.message("Login produced an auth.json that does not look like Codex auth")
        }
        try self.vault.saveAuthBlob(data, profileID: profile)
        try self.saveActiveProfileIfMissing(profile)
        self.note("Saved auth for profile '\(profile)' in macOS Keychain")
    }

    private static func commandApp(_ args: [String]) throws {
        guard let profile = args.first else {
            throw CLIError.message("Usage: \(self.program) app <profile> [workspace]")
        }
        try self.validateProfile(profile)

        let targetData = try self.vault.loadAuthBlob(profileID: profile)
        guard let targetData else {
            throw CLIError.message("No saved auth for profile '\(profile)'. Run '\(self.program) login \(profile)' first.")
        }

        let requestedWorkspace = args.dropFirst().first
        let workspace = try self.resolveWorkspace(requestedWorkspace)
        let codexAppBin = try self.codexAppBinary()
        try self.ensurePrivateDir(self.liveCodexHome())

        var outgoingProfile: String?
        if let liveData = try? Data(contentsOf: self.liveAuthPath()) {
            let matches = try self.matchingProfiles(for: liveData)
            if matches.count == 1 {
                outgoingProfile = matches[0]
                if outgoingProfile == profile, self.codexDesktopRunning() {
                    self.note("Profile '\(profile)' is already active.")
                    return
                }
            } else if matches.count > 1 {
                let active = self.loadConfig()?.activeProfile ?? ""
                if matches.contains(active) {
                    outgoingProfile = active
                } else {
                    throw CLIError.message("Live auth matches multiple saved profiles and config.activeProfile is not one of them.")
                }
            } else {
                throw CLIError.message("Live auth does not match any saved profile. Refusing to overwrite ~/.codex/auth.json until the current account is saved in the switcher.")
            }
        }

        try self.quitCodexApp()
        if let outgoingProfile,
           let liveData = try? Data(contentsOf: self.liveAuthPath()) {
            try self.vault.saveAuthBlob(liveData, profileID: outgoingProfile)
        }

        try self.atomicWrite(targetData, to: self.liveAuthPath())
        try self.saveActiveProfile(profile)
        try self.launchCodexApp(codexAppBin, workspace: workspace)
    }

    private static func commandStatus(_ args: [String]) throws {
        if let profile = args.first {
            try self.validateProfile(profile)
            try self.printStatus(profile)
            return
        }

        let profiles = try self.vault.listProfileIDs().filter(self.isValidProfile).sorted()
        if profiles.isEmpty {
            self.note("No saved auth profiles. Create one with: \(self.program) login <profile>")
            return
        }
        for profile in profiles {
            try self.printStatus(profile)
        }
    }

    private static func commandList() throws {
        let profiles = try self.vault.listProfileIDs().filter(self.isValidProfile).sorted()
        if profiles.isEmpty {
            self.note("No saved auth profiles. Create one with: \(self.program) login <profile>")
            return
        }
        for profile in profiles {
            print("  \(profile) -> \(self.vaultLocation(profile: profile))")
        }
    }

    private static func commandPath(_ args: [String]) throws {
        guard let profile = args.first else {
            throw CLIError.message("Usage: \(self.program) path <profile>")
        }
        try self.validateProfile(profile)
        print(self.vaultLocation(profile: profile))
    }

    private static func commandDoctor() throws {
        self.note("Codex profile doctor")
        self.note("")
        if let desktop = try? self.codexAppBinary() {
            self.note("Desktop: \(desktop)")
        } else {
            self.note("Desktop: missing (\(self.codexAppPath())/Contents/MacOS/Codex)")
        }

        if let cli = try? self.findCodexCLI() {
            self.note("CLI: \(cli)")
            _ = self.runAndWait(cli, arguments: ["--version"])
        } else {
            self.note("CLI: missing")
        }

        self.note("")
        self.note("Saved profiles:")
        try self.commandList()
        self.note("")
        self.note("Saved auth status (vault metadata only):")
        try self.commandStatus([])
    }

    private static func printStatus(_ profile: String) throws {
        guard let data = try self.vault.loadAuthBlob(profileID: profile) else {
            print("  \(profile): Not set up")
            return
        }
        if let accountID = self.readAccountID(from: data) {
            if accountID == "api-key" {
                print("  \(profile): Saved API key auth")
            } else {
                print("  \(profile): Saved account \(accountID)")
            }
        } else {
            print("  \(profile): Saved auth (account unknown)")
        }
    }

    private static func matchingProfiles(for liveData: Data) throws -> [String] {
        guard let liveFingerprint = AuthBlob.identityFingerprint(from: liveData) else { return [] }
        return try self.vault.listProfileIDs()
            .filter(self.isValidProfile)
            .filter { profile in
                guard let data = try? self.vault.loadAuthBlob(profileID: profile) else { return false }
                return AuthBlob.identityFingerprint(from: data) == liveFingerprint
            }
            .sorted()
    }

    private static func readAccountID(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let tokens = json["tokens"] as? [String: Any] {
            if let accountID = tokens["account_id"] as? String, !accountID.isEmpty { return accountID }
            if let accountID = tokens["accountId"] as? String, !accountID.isEmpty { return accountID }
        }
        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "api-key"
        }
        return nil
    }

    private static func resolveWorkspace(_ requested: String?) throws -> String? {
        guard let requested, !requested.isEmpty else {
            return self.resolveWorkspaceFromGlobalState()
        }
        var isDir = ObjCBool(false)
        guard self.fileManager.fileExists(atPath: requested, isDirectory: &isDir), isDir.boolValue else {
            throw CLIError.message("Workspace directory not found: \(requested)")
        }
        return URL(fileURLWithPath: requested).standardizedFileURL.path
    }

    private static func resolveWorkspaceFromGlobalState() -> String? {
        guard let data = try? Data(contentsOf: self.codexGlobalStatePath()),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        for key in ["active-workspace-roots", "electron-saved-workspace-roots"] {
            guard let values = json[key] as? [String] else { continue }
            for value in values where !value.isEmpty {
                var isDir = ObjCBool(false)
                if self.fileManager.fileExists(atPath: value, isDirectory: &isDir), isDir.boolValue {
                    return URL(fileURLWithPath: value).standardizedFileURL.path
                }
            }
        }
        return nil
    }

    private static func saveActiveProfileIfMissing(_ profile: String) throws {
        if self.loadConfig()?.activeProfile == nil {
            try self.saveActiveProfile(profile)
        }
    }

    private static func saveActiveProfile(_ profile: String) throws {
        try self.ensurePrivateDir(self.switcherHome())
        var config = self.loadConfig() ?? CLIConfig(profiles: [], activeProfile: profile, authStorageVersion: self.storageVersion)
        config.activeProfile = profile
        config.authStorageVersion = self.storageVersion
        if !config.profiles.contains(where: { $0.id == profile }) {
            config.profiles.append(CLIProfileConfig(id: profile, label: "Profile \(profile)"))
        }
        let data = try JSONEncoder.prettySorted.encode(config)
        try self.atomicWrite(data, to: self.configPath())
    }

    private static func loadConfig() -> CLIConfig? {
        guard let data = try? Data(contentsOf: self.configPath()) else { return nil }
        return try? JSONDecoder().decode(CLIConfig.self, from: data)
    }

    private static func launchCodexApp(_ path: String, workspace: String?) throws {
        let logDir = self.liveCodexHome().appendingPathComponent("logs", isDirectory: true)
        try self.ensurePrivateDir(logDir)
        let logFile = logDir.appendingPathComponent("desktop.log")
        self.fileManager.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])

        self.note("Launching Codex Desktop")
        self.note("Log: \(logFile.path)")
        if let workspace {
            self.note("Workspace: \(workspace)")
        } else {
            self.note("Workspace: <default>")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = workspace.map { [$0] } ?? []
        let handle = try FileHandle(forWritingTo: logFile)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
    }

    private static func quitCodexApp() throws {
        guard self.codexDesktopRunning() else { return }
        self.note("Quitting existing Codex app...")
        _ = self.runAndWait("/usr/bin/osascript", arguments: ["-e", "tell application \"Codex\" to quit"])

        let attempts = Int(self.environment("CODEX_PROFILE_QUIT_ATTEMPTS") ?? "") ?? 30
        let sleepSeconds = Double(self.environment("CODEX_PROFILE_QUIT_SLEEP") ?? "") ?? 0.5
        for _ in 0..<attempts {
            if !self.codexDesktopRunning() { return }
            Thread.sleep(forTimeInterval: sleepSeconds)
        }
        throw CLIError.message("Codex or its app-server is still running. Quit Codex with Cmd+Q, then retry.")
    }

    private static func codexDesktopRunning() -> Bool {
        if self.environment("CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED") == "1" {
            return false
        }
        return self.runAndWait("/usr/bin/pgrep", arguments: ["-x", "Codex"], quiet: true) == 0
            || self.runAndWait("/usr/bin/pgrep", arguments: ["-f", "\(self.codexBundledCLI()) app-server"], quiet: true) == 0
    }

    private static func findCodexCLI() throws -> String {
        if let override = self.environment("CODEX_CLI"), !override.isEmpty {
            guard self.fileManager.isExecutableFile(atPath: override) else {
                throw CLIError.message("CODEX_CLI is set but not executable: \(override)")
            }
            return override
        }
        let bundled = self.codexBundledCLI()
        if self.fileManager.isExecutableFile(atPath: bundled) {
            return bundled
        }
        if let path = self.which("codex") {
            return path
        }
        throw CLIError.message("Codex CLI not found. Install Codex or set CODEX_CLI=/path/to/codex.")
    }

    private static func codexAppBinary() throws -> String {
        let path = self.environment("CODEX_APP_BIN") ?? "\(self.codexAppPath())/Contents/MacOS/Codex"
        guard self.fileManager.isExecutableFile(atPath: path) else {
            throw CLIError.message("Codex Desktop binary not found at \(path)")
        }
        return path
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.environment = ["PATH": self.effectivePATH()]
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func runAndWait(
        _ executable: String,
        arguments: [String],
        environment extraEnvironment: [String: String] = [:],
        quiet: Bool = false
    ) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in extraEnvironment { env[key] = value }
        env["PATH"] = self.effectivePATH()
        process.environment = env
        if quiet {
            process.standardOutput = Pipe()
            process.standardError = Pipe()
        }
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 127
        }
    }

    private static func makeTempHome(profile: String) throws -> URL {
        let tmpRoot = self.switcherHome().appendingPathComponent("tmp", isDirectory: true)
        try self.ensurePrivateDir(tmpRoot)
        let url = tmpRoot.appendingPathComponent("\(profile)-\(UUID().uuidString)", isDirectory: true)
        try self.ensurePrivateDir(url)
        return url
    }

    private static func ensurePrivateDir(_ url: URL) throws {
        try self.fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private static func atomicWrite(_ data: Data, to destination: URL) throws {
        try self.ensurePrivateDir(destination.deletingLastPathComponent())
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: .withoutOverwriting)
        try self.fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        if self.fileManager.fileExists(atPath: destination.path) {
            _ = try self.fileManager.replaceItemAt(destination, withItemAt: temp)
        } else {
            try self.fileManager.moveItem(at: temp, to: destination)
        }
    }

    private static func validateProfile(_ profile: String) throws {
        guard self.isValidProfile(profile) else {
            throw CLIError.message("Invalid profile '\(profile)'. Use letters, numbers, dots, dashes, or underscores.")
        }
    }

    private static func isValidProfile(_ profile: String) -> Bool {
        profile.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    private static func effectivePATH() -> String {
        let home = self.userHome().path
        let chunks = [
            self.environment("PATH"),
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].compactMap { $0 }

        var seen = Set<String>()
        var parts: [String] = []
        for chunk in chunks {
            for part in chunk.split(separator: ":").map(String.init) where !part.isEmpty {
                if seen.insert(part).inserted {
                    parts.append(part)
                }
            }
        }
        return parts.joined(separator: ":")
    }

    private static func codexAppPath() -> String {
        self.environment("CODEX_APP") ?? "/Applications/Codex.app"
    }

    private static func codexBundledCLI() -> String {
        self.environment("CODEX_BUNDLED_CLI") ?? "\(self.codexAppPath())/Contents/Resources/codex"
    }

    private static func switcherHome() -> URL {
        self.userHome().appendingPathComponent(".codex-switcher", isDirectory: true)
    }

    private static func liveCodexHome() -> URL {
        self.userHome().appendingPathComponent(".codex", isDirectory: true)
    }

    private static func configPath() -> URL {
        self.switcherHome().appendingPathComponent("config.json")
    }

    private static func liveAuthPath() -> URL {
        self.liveCodexHome().appendingPathComponent("auth.json")
    }

    private static func codexGlobalStatePath() -> URL {
        self.liveCodexHome().appendingPathComponent(".codex-global-state.json")
    }

    private static func environment(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    private static func makeVault() -> AuthVault {
        if let path = self.environment("CODEX_PROFILE_TEST_AUTH_STORE_DIR"), !path.isEmpty {
            return FileAuthVault(root: URL(fileURLWithPath: path).standardizedFileURL)
        }
        return KeychainAuthVault(service: self.keychainService)
    }

    private static func vaultLocation(profile: String) -> String {
        if let path = self.environment("CODEX_PROFILE_TEST_AUTH_STORE_DIR"), !path.isEmpty {
            return URL(fileURLWithPath: path)
                .appendingPathComponent("\(profile).json")
                .standardizedFileURL
                .path
        }
        return "keychain://\(self.keychainService)/\(profile)"
    }

    private static func userHome() -> URL {
        if let path = self.environment("CODEX_PROFILE_HOME"), !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        if let path = self.environment("CODEX_PROFILE_TEST_HOME"), !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return self.fileManager.homeDirectoryForCurrentUser
    }

    private static func note(_ text: String) {
        print(text)
    }
}

private extension JSONEncoder {
    static let prettySorted: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
