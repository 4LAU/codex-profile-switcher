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
    private static let keychainAccessRepairVersion = 3

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
            case "migrate": try self.commandMigrate(args)
            case "keychain-repair": try self.commandKeychainRepair()
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
          \(self.program) doctor [--check-legacy]
          \(self.program) migrate --status|--all
          \(self.program) keychain-repair
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

        let requestedWorkspace = args.dropFirst().first
        let workspace = try self.resolveWorkspace(requestedWorkspace)
        let codexAppBin = try self.codexAppBinary()
        let transaction = try ProfileTransactionService(
            vault: self.vault,
            paths: self.paths,
            isCodexDesktopRunning: self.codexDesktopRunning
        ).prepareSwitch(to: profile)
        if transaction.alreadyActive {
            self.note("Profile '\(profile)' is already active.")
            return
        }

        try self.quitCodexApp()
        _ = try transaction.commit()
        do {
            try self.launchCodexApp(codexAppBin, workspace: workspace)
        } catch {
            throw CLIError.message("Profile switched. Codex Desktop may need a manual restart.")
        }
    }

    private static func commandStatus(_ args: [String]) throws {
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
        let checkLegacy = args.contains("--check-legacy")
        let unknownArgs = args.filter { $0 != "--check-legacy" }
        guard unknownArgs.isEmpty else {
            throw CLIError.message("Usage: \(self.program) doctor [--check-legacy]")
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
        self.note("  keychain access group: \(diagnostics.accessGroup ?? "<none>")")
        self.note("  data protection probe: \(diagnostics.dataProtectionProbe ?? "<none>")")
        self.note("  embedded keychain access groups: \(self.embeddedAccessGroupsDescription())")
        self.note("  migration complete: \(self.configStore.loadConfig()?.migrationComplete == true)")

        self.note("")
        self.note("Saved profiles:")
        try self.commandList()
        self.note("")
        self.note("Saved auth status (vault metadata only):")
        try self.printMetadataStatuses(vault: self.vault)

        if checkLegacy {
            self.note("")
            self.note("Legacy auth inspection (may prompt):")
            try self.printMetadataStatuses(vault: self.makeLegacyInspectionVault())
        }
    }

    private static func commandKeychainRepair() throws {
        let repaired = try self.vault.repairStoredAuthAccess()
        try self.configStore.markAuthStorageVersion(Self.keychainAccessRepairVersion)
        self.note("Rewrote \(repaired) saved auth item(s) with current Keychain access settings.")
    }

    private static func commandMigrate(_ args: [String]) throws {
        guard args.count == 1, let mode = args.first, ["--status", "--all"].contains(mode) else {
            throw CLIError.message("Usage: \(self.program) migrate --status|--all")
        }

        let legacyVault = self.makeLegacyInspectionVault()
        if mode == "--status" {
            self.note("Legacy auth migration status (may prompt):")
            try self.printMetadataStatuses(vault: legacyVault)
            return
        }

        guard self.vault.diagnostics().activeBackend == .dataProtectionShared else {
            throw CLIError.message("Data protection Keychain is not active; cannot migrate legacy items.")
        }

        let profiles = try legacyVault.listProfileIDs()
            .filter(ProfileValidator.isValid)
            .sorted()
        if profiles.isEmpty {
            try self.configStore.markMigrationComplete(true)
            self.note("No legacy auth items found. Marked migration complete.")
            return
        }

        var migrated = 0
        var cleaned = 0
        for profile in profiles {
            if try self.migrateLegacyProfile(profile, legacyVault: legacyVault) {
                migrated += 1
            } else {
                cleaned += 1
            }
        }
        try self.configStore.ensureProfiles(profiles)
        try self.configStore.markMigrationComplete(true)
        self.note("Migrated \(migrated) legacy auth item(s) to the data protection Keychain; cleaned \(cleaned) stale legacy item(s).")
    }

    private static func printStatus(_ profile: String) throws {
        let availability = try self.vault.authBlobAvailability(profileID: profile)
        if availability == .needsMigration {
            print("  \(profile): Needs migration")
            return
        }
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
            case .needsMigration:
                print("  \(profile): Needs migration")
            case .missing:
                print("  \(profile): Not set up")
            }
        }
    }

    private static func migrateLegacyProfile(_ profile: String, legacyVault: AuthVault) throws -> Bool {
        if let existingData = try self.vault.loadAuthBlob(profileID: profile) {
            try legacyVault.deleteAuthBlob(profileID: profile)
            try self.vault.saveAuthBlob(existingData, profileID: profile)
            guard try self.vault.loadAuthBlob(profileID: profile) == existingData else {
                throw CLIError.message("Could not verify preserved auth for profile '\(profile)'")
            }
            return false
        }

        guard let legacyData = try legacyVault.loadAuthBlob(profileID: profile) else {
            return false
        }
        try self.vault.saveAuthBlob(legacyData, profileID: profile)
        guard try self.vault.loadAuthBlob(profileID: profile) == legacyData else {
            throw CLIError.message("Could not verify migrated auth for profile '\(profile)'")
        }
        try legacyVault.deleteAuthBlob(profileID: profile)
        try self.vault.saveAuthBlob(legacyData, profileID: profile)
        guard try self.vault.loadAuthBlob(profileID: profile) == legacyData else {
            throw CLIError.message("Could not verify migrated auth after legacy cleanup for profile '\(profile)'")
        }
        return true
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

    private static func launchCodexApp(_ path: String, workspace: String?) throws {
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
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = workspace.map { [$0] } ?? []
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
        return MigratingAuthVault(
            service: self.keychainService,
            accessGroup: KeychainAccessGroupResolver.configuredAccessGroup(),
            migrationComplete: self.configStore.loadConfig()?.migrationComplete == true
        )
    }

    private static func makeLegacyInspectionVault() -> AuthVault {
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
        var ids = Set(try vault.listProfileIDs().filter(ProfileValidator.isValid))
        if vault.diagnostics().activeBackend == .dataProtectionShared {
            for profile in self.configStore.loadConfig()?.profiles ?? [] where ProfileValidator.isValid(profile.id) {
                ids.insert(profile.id)
            }
        }
        return ids.sorted()
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
        case .dataProtectionShared:
            return "macOS data protection Keychain"
        case .legacyACL:
            return "macOS legacy ACL Keychain"
        case .file:
            return "file auth vault"
        case .custom:
            return "custom auth vault"
        }
    }

    private static func embeddedAccessGroupsDescription() -> String {
        let groups = KeychainAccessGroupResolver.embeddedKeychainAccessGroups()
        return groups.isEmpty ? "<none>" : groups.joined(separator: ",")
    }

    private static func note(_ text: String) {
        print(text)
    }
}
