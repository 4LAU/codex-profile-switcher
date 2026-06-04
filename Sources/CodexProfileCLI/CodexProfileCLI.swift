import CodexProfileCore
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

@main
enum CodexProfileCLI {
    private static let program = URL(fileURLWithPath: CommandLine.arguments.first ?? "codex-profile").lastPathComponent
    private static let fileManager = FileManager.default
    private static let paths = AppPaths()
    private static let configStore = ProfileConfigStore(paths: Self.paths)
    private static let keychainService = Self.environment("CODEX_PROFILE_KEYCHAIN_SERVICE")
        ?? KeychainAuthVault.defaultService
    private static let vault = Self.makeVault()
    private static let keychainAccessRepairVersion = 4

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
            case "doctor": try self.commandDoctor(args)
            case "keychain-repair": try self.commandKeychainRepair()
            case "best-auth": try self.commandBestAuth(args)
            case "mark-exhausted": try self.commandMarkExhausted(args)
            case "import-auth": try self.commandImportAuth(args)
            case "help", "-h", "--help": self.usage()
            default: throw CLIError.message("Unknown command '\(command)'. See \(self.program) help.")
            }
        } catch CLIError.exitStatus(let status) {
            exit(status)
        } catch let error as DuplicateAwareAuthSaverError {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
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
          \(self.program) keychain-repair
          \(self.program) best-auth --dir <path> [--exclude <id1,id2,...>]
          \(self.program) mark-exhausted <profile> [--until <iso8601>]
          \(self.program) import-auth --dir <path> --profile <id>
        """)
    }

    private static func commandLogin(_ args: [String]) throws {
        guard let profile = args.first else {
            throw CLIError.message("Usage: \(self.program) login <profile> [codex-login-args...]")
        }
        try self.validateProfile(profile)
        self.repairKeychainAccessIfNeeded()

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
        try DuplicateAwareAuthSaver.save(
            data,
            profileID: profile,
            profiles: try self.duplicateCheckProfiles(including: profile),
            vault: self.vault)
        try self.configStore.saveActiveProfileIfMissing(profile)
        self.note("Saved auth for profile '\(profile)' in \(self.authStorageLabel())")
    }

    private static func commandApp(_ args: [String]) throws {
        guard let profile = args.first else {
            throw CLIError.message("Usage: \(self.program) app <profile> [workspace]")
        }
        try self.validateProfile(profile)
        let repairComplete = self.repairKeychainAccessIfNeeded(markComplete: false)

        let requestedWorkspace = args.dropFirst().first
        let workspace = try self.resolveWorkspace(requestedWorkspace)
        let cli = self.codexBundledCLI()
        guard self.fileManager.isExecutableFile(atPath: cli) else {
            throw CLIError.message("Codex CLI not found at \(cli)")
        }
        let transaction = try ProfileTransactionService(
            vault: self.vault,
            paths: self.paths,
            isCodexDesktopRunning: self.codexDesktopRunning
        ).prepareSwitch(to: profile)
        if transaction.alreadyActive {
            if repairComplete {
                self.markKeychainAccessRepairComplete()
            }
            self.note("Profile '\(profile)' is already active.")
            return
        }

        try self.quitCodexApp()
        _ = try transaction.commit()
        if repairComplete {
            self.markKeychainAccessRepairComplete()
        }
        do {
            try self.launchCodexApp(workspace: workspace)
        } catch {
            throw CLIError.message("Profile switched. Codex Desktop may need a manual restart.")
        }
    }

    private static func commandStatus(_ args: [String]) throws {
        self.repairKeychainAccessIfNeeded()

        if let profile = args.first {
            try self.validateProfile(profile)
            try self.printStatus(profile)
            return
        }

        let profiles = try self.knownProfileIDs()
        if profiles.isEmpty {
            self.note("No saved auth profiles. Create one with: \(self.program) login <profile>")
            return
        }
        for profile in profiles {
            try self.printStatus(profile)
        }
    }

    private static func commandList() throws {
        let profiles = try self.knownProfileIDs()
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

    private static func commandDoctor(_ args: [String]) throws {
        guard args.isEmpty else {
            throw CLIError.message("Usage: \(self.program) doctor")
        }

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

        let diagnostics = self.vault.diagnostics()
        self.note("")
        self.note("Auth storage:")
        self.note("  backend: \(diagnostics.activeBackend.rawValue)")
        self.note("  keychain service: \(self.keychainService)")

        let configProfiles = self.configStore.loadConfig()?.profiles ?? []
        let savedIDs = Set(try self.vault.listProfileIDs().filter(ProfileValidator.isValid))
        let orphanedSlots = configProfiles.filter { !savedIDs.contains($0.id) }
        if !orphanedSlots.isEmpty {
            self.note("")
            self.note("Warning: \(orphanedSlots.count) configured profile(s) have no saved auth.")
            self.note("  This may happen after upgrading from a data-protection Keychain build.")
            self.note("  Re-login with: \(self.program) login <profile>")
        }

        self.note("")
        self.note("Saved profiles:")
        try self.commandList()
        self.note("")
        self.note("Saved auth status (vault metadata only):")
        try self.printMetadataStatuses(vault: self.vault)
    }

    private static func commandKeychainRepair() throws {
        let result = try self.vault.repairStoredAuthAccess()
        if result.isComplete {
            try self.configStore.markAuthStorageVersion(Self.keychainAccessRepairVersion)
        }
        self.note("Rewrote \(result.repaired)/\(result.total) saved auth item(s) with current Keychain access settings.")
        if !result.isComplete {
            self.note("Some items could not be repaired. Run again to retry.")
        }
    }

    @discardableResult
    private static func repairKeychainAccessIfNeeded(markComplete: Bool = true) -> Bool {
        let currentVersion = self.configStore.loadConfig()?.authStorageVersion ?? 0
        guard currentVersion >= 2,
              currentVersion < Self.keychainAccessRepairVersion else { return false }

        guard let result = try? self.vault.repairStoredAuthAccess() else { return false }
        if result.isComplete, markComplete {
            self.markKeychainAccessRepairComplete()
        }
        return result.isComplete
    }

    private static func markKeychainAccessRepairComplete() {
        try? self.configStore.markAuthStorageVersion(Self.keychainAccessRepairVersion)
    }

    private static func commandBestAuth(_ args: [String]) throws {
        var dir: String?
        var excludeCSV: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--dir":
                guard i + 1 < args.count else {
                    throw CLIError.message("--dir requires a path argument")
                }
                i += 1
                dir = args[i]
            case "--exclude":
                guard i + 1 < args.count else {
                    throw CLIError.message("--exclude requires a comma-separated list")
                }
                i += 1
                excludeCSV = args[i]
            default:
                throw CLIError.message("Unknown argument: \(args[i]). Usage: \(self.program) best-auth --dir <path> [--exclude <id1,id2,...>]")
            }
            i += 1
        }

        guard let dir else {
            throw CLIError.message("Usage: \(self.program) best-auth --dir <path> [--exclude <id1,id2,...>]")
        }
        self.repairKeychainAccessIfNeeded()

        let excludeIDs = Set((excludeCSV ?? "")
            .split(separator: ",")
            .map(String.init)
            .filter { !$0.isEmpty })
        let config = self.configStore.loadConfig() ?? AppConfig(profiles: [], activeProfile: "")
        let cache = self.loadCache()
        let eligibleProfiles = config.profiles
            .filter { profile in
                let availability = try? self.vault.authBlobAvailability(profileID: profile.id)
                return availability == .present
            }

        if config.profiles.isEmpty {
            fputs("No profiles configured\n", stderr)
            throw CLIError.exitStatus(3)
        }

        guard let result = ProfileSelector.selectBest(
            profiles: eligibleProfiles,
            cache: cache,
            excludeIDs: excludeIDs
        ) else {
            fputs("No eligible profiles available\n", stderr)
            throw CLIError.exitStatus(1)
        }

        let dirURL = URL(fileURLWithPath: dir)
        try self.ensurePrivateDir(dirURL)

        guard let authData = try self.vault.loadAuthBlob(profileID: result.profileID) else {
            fputs("No auth data for profile '\(result.profileID)'\n", stderr)
            throw CLIError.exitStatus(1)
        }
        try AtomicFileWriter.write(authData, to: dirURL.appendingPathComponent("auth.json"))

        let liveConfig = self.paths.liveCodexHome.appendingPathComponent("config.toml")
        let destination = dirURL.appendingPathComponent("config.toml")
        try? self.fileManager.removeItem(at: destination)
        if self.fileManager.fileExists(atPath: liveConfig.path) {
            try self.fileManager.copyItem(at: liveConfig, to: destination)
        }

        print(result.profileID)
    }

    private static func commandMarkExhausted(_ args: [String]) throws {
        var profile: String?
        var untilISO: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--until":
                guard i + 1 < args.count else {
                    throw CLIError.message("--until requires an ISO 8601 timestamp")
                }
                i += 1
                untilISO = args[i]
            default:
                if profile == nil {
                    profile = args[i]
                } else {
                    throw CLIError.message("Unknown argument: \(args[i])")
                }
            }
            i += 1
        }

        guard let profile else {
            throw CLIError.message("Usage: \(self.program) mark-exhausted <profile> [--until <iso8601>]")
        }
        try self.validateProfile(profile)

        let blockedUntil: Date
        if let untilISO {
            guard let parsed = ISO8601DateFormatter().date(from: untilISO) else {
                throw CLIError.message("--until requires an ISO 8601 timestamp")
            }
            blockedUntil = parsed
        } else {
            blockedUntil = Date().addingTimeInterval(3600)
        }

        var cache = self.loadCache()
        cache.exhaustionOverrides[profile] = ExhaustionOverride(
            blockedUntil: blockedUntil,
            reason: "rate_limit",
            source: "codex_exec")

        try self.saveCache(cache)
        self.note("Marked '\(profile)' exhausted until \(ISO8601DateFormatter().string(from: blockedUntil))")
    }

    private static func commandImportAuth(_ args: [String]) throws {
        var dir: String?
        var profile: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--dir":
                guard i + 1 < args.count else {
                    throw CLIError.message("--dir requires a path argument")
                }
                i += 1
                dir = args[i]
            case "--profile":
                guard i + 1 < args.count else {
                    throw CLIError.message("--profile requires a profile ID")
                }
                i += 1
                profile = args[i]
            default:
                throw CLIError.message("Unknown argument: \(args[i])")
            }
            i += 1
        }

        guard let dir, let profile else {
            throw CLIError.message("Usage: \(self.program) import-auth --dir <path> --profile <id>")
        }
        try self.validateProfile(profile)
        self.repairKeychainAccessIfNeeded()

        let authURL = URL(fileURLWithPath: dir).appendingPathComponent("auth.json")
        guard let updatedData = try? Data(contentsOf: authURL) else {
            fputs("No auth data found at \(authURL.path)\n", stderr)
            throw CLIError.exitStatus(1)
        }
        guard let existingData = try self.vault.loadAuthBlob(profileID: profile) else {
            fputs("No existing auth data for profile '\(profile)'\n", stderr)
            throw CLIError.exitStatus(1)
        }
        guard updatedData != existingData else { return }
        guard AuthBlob.isPlausibleAuthBlob(updatedData) else {
            fputs("Warning: temp auth.json failed validation - preserving existing credential\n", stderr)
            throw CLIError.exitStatus(2)
        }

        do {
            _ = try AuthBlob.load(from: updatedData)
        } catch {
            fputs("Warning: temp auth.json has invalid token structure - preserving existing credential\n", stderr)
            throw CLIError.exitStatus(2)
        }

        let existingFingerprint = AuthBlob.identityFingerprint(from: existingData)
        let updatedFingerprint = AuthBlob.identityFingerprint(from: updatedData)
        guard let existingFingerprint, let updatedFingerprint else {
            fputs("Warning: temp auth.json identity could not be verified - preserving existing credential\n", stderr)
            throw CLIError.exitStatus(2)
        }
        if existingFingerprint != updatedFingerprint {
            fputs("Warning: temp auth.json has different identity - preserving existing credential\n", stderr)
            throw CLIError.exitStatus(2)
        }

        try self.vault.saveAuthBlob(updatedData, profileID: profile)
    }

    private static func printStatus(_ profile: String) throws {
        let availability = try self.vault.authBlobAvailability(profileID: profile)
        if availability == .missing {
            print("  \(profile): Not set up")
            return
        }

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

    private static func printMetadataStatuses(vault: AuthVault) throws {
        let profiles = try self.knownProfileIDs(vault: vault)
        if profiles.isEmpty {
            self.note("  <none>")
            return
        }

        for profile in profiles {
            switch try vault.authBlobAvailability(profileID: profile) {
            case .present:
                print("  \(profile): Saved auth")
            case .missing:
                print("  \(profile): Not set up")
            }
        }
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
        guard let data = try? Data(contentsOf: self.paths.globalStateURL),
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

    private static func launchCodexApp(workspace: String?) throws {
        let cli = self.codexBundledCLI()
        guard self.fileManager.isExecutableFile(atPath: cli) else {
            throw CLIError.message("Codex CLI not found at \(cli)")
        }
        let logDir = self.paths.liveCodexHome.appendingPathComponent("logs", isDirectory: true)
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
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["app"] + (workspace.map { [$0] } ?? [])
        let handle = try FileHandle(forWritingTo: logFile)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        try? handle.close()
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
        let tmpRoot = self.paths.tempRoot
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
        try self.fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func loadCache() -> UsageCache {
        let decoder = JSONDecoder.iso8601Decoder()
        return (try? Data(contentsOf: self.paths.cacheURL))
            .flatMap { try? decoder.decode(UsageCache.self, from: $0) }
            ?? UsageCache(snapshots: [:])
    }

    private static func saveCache(_ cache: UsageCache) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cache)
        try AtomicFileWriter.write(data, to: self.paths.cacheURL)
    }

    private static func validateProfile(_ profile: String) throws {
        try ProfileValidator.validate(profile)
    }

    private static func effectivePATH() -> String {
        let home = self.paths.userHome.path
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

    private static func environment(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    private static func makeVault() -> AuthVault {
        if let path = self.environment("CODEX_PROFILE_TEST_AUTH_STORE_DIR"), !path.isEmpty {
            return FileAuthVault(root: URL(fileURLWithPath: path).standardizedFileURL)
        }
        return LegacyKeychainAuthVault(service: self.keychainService)
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

    private static func knownProfileIDs(vault: AuthVault = Self.vault) throws -> [String] {
        try vault.listProfileIDs().filter(ProfileValidator.isValid).sorted()
    }

    private static func duplicateCheckProfiles(including profileID: String) throws -> [ProfileConfig] {
        var labelsByID: [String: String] = [:]
        for profile in self.configStore.loadConfig()?.profiles ?? [] where ProfileValidator.isValid(profile.id) {
            labelsByID[profile.id] = profile.label
        }
        for id in try self.vault.listProfileIDs().filter(ProfileValidator.isValid) {
            labelsByID[id] = labelsByID[id] ?? "Profile \(id)"
        }
        labelsByID[profileID] = labelsByID[profileID] ?? "Profile \(profileID)"
        return labelsByID
            .map { ProfileConfig(id: $0.key, label: $0.value) }
            .sorted { $0.id < $1.id }
    }

    private static func authStorageLabel() -> String {
        switch self.vault.diagnostics().activeBackend {
        case .legacyACL:
            return "macOS Keychain"
        case .file:
            return "file auth vault"
        case .custom:
            return "custom auth vault"
        }
    }

    private static func note(_ text: String) {
        print(text)
    }
}

private extension JSONDecoder {
    static func iso8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
