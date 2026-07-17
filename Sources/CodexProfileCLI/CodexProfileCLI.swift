import CodexProfileCore
import CryptoKit
import Foundation
import Security

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

/// PID of the child process `exec` is currently running, read by the C signal
/// handler below (which cannot capture context). 0 when no child is active.
private nonisolated(unsafe) var execChildPID: pid_t = 0

/// Forwards SIGINT/SIGTERM to the active `exec` child so the wrapper survives
/// long enough to import refreshed auth and remove its temp home.
private func execForwardSignal(_ signalNumber: Int32) {
    let pid = execChildPID
    if pid > 0 {
        kill(pid, signalNumber)
    }
}

/// Stable process exit codes. External tooling depends on these — keep stable.
private enum ExitCode {
    static let success: Int32 = 0
    static let noEligibleProfile: Int32 = 2
    static let noProfilesConfigured: Int32 = 3
    static let usageDataUnavailable: Int32 = 4
    static let identityMismatch: Int32 = 5
    static let keychainInteractionRequired: Int32 = 6
    static let watchdogTimeout: Int32 = 7
    // 1 = generic failure (default in main()).
}

@main
enum CodexProfileCLI {
    private static let program = URL(fileURLWithPath: CommandLine.arguments.first ?? "codex-profile").lastPathComponent
    private static let fileManager = FileManager.default
    private static let paths = AppPaths()
    private static let configStore = ProfileConfigStore(paths: Self.paths)
    private static let vault = Self.makeVault()
    private static let version = "0.5.12"
    private static let signedSmokeServicePrefix = "com.4lau.codex-profile-switcher.auth.smoke."
    private static let signedSmokeLegacyServicePrefix = "com.4lau.codex-profile-switcher.auth.legacy-smoke."

    /// True when no controlling terminal is attached to stdin. In this mode the
    /// CLI must never trigger a modal Keychain consent prompt (it would hang
    /// with no UI to render).
    private static var stdinIsTTY: Bool { isatty(0) != 0 }

    static func main() {
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            let command = args.isEmpty ? "help" : args.removeFirst()
            switch command {
            case "app": try self.commandApp(args)
            case "login": try self.commandLogin(args)
            case "status": try self.commandStatus(args)
            case "list": try self.commandList(args)
            case "path": try self.commandPath(args)
            case "doctor": try self.commandDoctor(args)
            case "keychain-repair": try self.commandKeychainRepair()
            case "signed-smoke-cleanup": try self.commandSignedSmokeCleanup(args)
            case "signed-smoke-migration": try self.commandSignedSmokeMigration()
            case "best-auth": try self.commandBestAuth(args)
            case "exec": try self.commandExec(args)
            case "mark-exhausted": try self.commandMarkExhausted(args)
            case "import-auth": try self.commandImportAuth(args)
            case "lease": try self.commandLease(args)
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
          \(self.program) status [profile] [--json]
          \(self.program) list [--json]
          \(self.program) path <profile>
          \(self.program) doctor
          \(self.program) keychain-repair
          \(self.program) best-auth --dir <path> [--exclude <id1,id2,...>] [--json] [--non-interactive] [--timeout <seconds>]
          \(self.program) exec [--max-attempts <n>] [--exclude <id1,id2,...>] [--timeout <seconds>] -- <command> [args...]
          \(self.program) import-auth --dir <path> --profile <id> [--non-interactive] [--timeout <seconds>]
          \(self.program) lease begin [--exclude <id1,id2,...>] [--ttl <seconds>] [--timeout <seconds>] [--json] [--non-interactive]
          \(self.program) lease swap <token> [--exclude <id1,id2,...>] [--ttl <seconds>] [--timeout <seconds>] [--json] [--non-interactive]
          \(self.program) lease end <token> [--profile <id>] [--timeout <seconds>] [--non-interactive]
          \(self.program) lease gc

        exec runs <command> with CODEX_HOME pointed at the best profile's
        credentials. If the command fails with a usage-limit error, the profile
        is marked exhausted and the command is retried on the next best profile
        (up to --max-attempts, default 3). stdin and stdout pass through
        untouched; refreshed tokens are written back to the profile afterwards.

        best-auth picks the profile with the most remaining quota for scripted
        account rotation. It fetches live usage (falling back to the cached
        usage file per profile) and prints the selected profile ID on stdout, or
        a machine-readable report with --json. Exit codes: 0 selected; 2 no
        eligible profile; 3 no profiles configured; 4 usage data unavailable;
        6 keychain interaction required (run once from a terminal to grant
        access); 7 watchdog timeout.

        import-auth writes back a refreshed auth.json for <id> only when its
        identity matches the stored credential (exit 5 on identity mismatch).

        lease begin reserves the profile with the most remaining quota for
        --ttl seconds (default 3600) and seeds a private throwaway CODEX_HOME
        for it. Profiles already holding an active lease are skipped so two
        concurrent runs never grab the same account. Prints the home path, or
        a JSON {profile, home, token, expires_at} with --json. Exit codes match
        best-auth (2 no eligible / 3 no profiles / 4 usage unavailable / 6
        keychain interaction required). lease swap <token> rotates the leased
        account to the next-best one in place (refreshed credential written
        back, old account marked exhausted) without disturbing the session, so
        a warm 'codex exec resume' stays warm. lease end <token> writes the
        refreshed credential back and tears the lease down; it is idempotent
        and trap-safe. lease gc removes expired lease homes and reclaims any
        home left behind by a crashed process.
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
        let lifecycle = CodexDesktopLifecycle()
        _ = try lifecycle.resolveBundledCLI()
        let transaction = try ProfileTransactionService(
            vault: self.vault,
            paths: self.paths,
            isCodexDesktopRunning: lifecycle.isDesktopRunning
        ).prepareSwitch(to: profile)
        if transaction.alreadyActive {
            self.note("Profile '\(profile)' is already active.")
            return
        }

        try lifecycle.stopDesktop()
        _ = try transaction.commit()
        do {
            let logURL = self.paths.liveCodexHome.appendingPathComponent("logs/desktop.log")
            try self.fileManager.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try lifecycle.launch(workspacePath: workspace, logURL: logURL)
        } catch {
            throw CLIError.message("Profile switched, but Codex Desktop could not be relaunched: \(error.localizedDescription)")
        }
    }

    private struct StatusEntry: Codable {
        let id: String
        let state: String
        let account: String?
    }

    private struct ListEntry: Codable {
        let id: String
        let location: String
    }

    private static func commandStatus(_ args: [String]) throws {
        let json = args.contains("--json")
        let positional = args.filter { $0 != "--json" }

        let profiles: [String]
        if let profile = positional.first {
            try self.validateProfile(profile)
            profiles = [profile]
        } else {
            profiles = try self.knownProfileIDs()
            if profiles.isEmpty, !json {
                self.note("No saved auth profiles. Create one with: \(self.program) login <profile>")
                return
            }
        }

        let entries = try profiles.map { try self.statusEntry($0) }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(entries), as: UTF8.self))
            return
        }
        for entry in entries {
            print("  \(entry.id): \(self.statusText(entry))")
        }
    }

    private static func commandList(_ args: [String]) throws {
        let json = args.contains("--json")
        let profiles = try self.knownProfileIDs()
        if profiles.isEmpty, !json {
            self.note("No saved auth profiles. Create one with: \(self.program) login <profile>")
            return
        }
        if json {
            let entries = profiles.map { ListEntry(id: $0, location: self.vaultLocation(profile: $0)) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(entries), as: UTF8.self))
            return
        }
        for profile in profiles {
            print("  \(profile) -> \(self.vaultLocation(profile: profile))")
        }
    }

    /// Computes a profile's status as structured data shared by text and JSON
    /// output. `state` is one of: not-set-up, api-key, account, unknown.
    private static func statusEntry(_ profile: String) throws -> StatusEntry {
        let availability = try self.vault.authBlobAvailability(profileID: profile)
        if availability == .missing {
            return StatusEntry(id: profile, state: "not-set-up", account: nil)
        }
        guard let data = try self.vault.loadAuthBlob(profileID: profile) else {
            return StatusEntry(id: profile, state: "not-set-up", account: nil)
        }
        if let accountID = self.readAccountID(from: data) {
            if accountID == "api-key" {
                return StatusEntry(id: profile, state: "api-key", account: nil)
            }
            return StatusEntry(id: profile, state: "account", account: accountID)
        }
        return StatusEntry(id: profile, state: "unknown", account: nil)
    }

    private static func statusText(_ entry: StatusEntry) -> String {
        switch entry.state {
        case "not-set-up": return "Not set up"
        case "api-key": return "Saved API key auth"
        case "account": return "Saved account \(entry.account ?? "")"
        default: return "Saved auth (account unknown)"
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
            self.note("Desktop: missing (install ChatGPT or set CODEX_APP)")
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
        self.note("  backend: \(diagnostics.activeBackend.displayName)")

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
        try self.commandList([])
        self.note("")
        self.note("Saved auth status (vault metadata only):")
        try self.printMetadataStatuses(vault: self.vault)
    }

    private static func commandKeychainRepair() throws {
        throw CLIError.message(
            "Keychain migration is available only in the app. Open Settings > General and choose “Review Legacy Keychain Copies…”. Legacy Keychain credentials were not changed.")
    }

    private static func commandSignedSmokeCleanup(_ args: [String]) throws {
        guard !args.isEmpty else {
            throw CLIError.message("signed-smoke-cleanup requires at least one profile ID")
        }
        for profile in args {
            try self.validateProfile(profile)
        }
        guard Set(args).count == args.count else {
            throw CLIError.message("signed-smoke-cleanup does not accept duplicate profile IDs")
        }
        guard self.vault.diagnostics().activeBackend == .dataProtectionKeychain else {
            throw CLIError.message("signed-smoke-cleanup requires the Data Protection Keychain vault")
        }
        guard self.environment("CODEX_PROFILE_SIGNED_SMOKE") == "1" else {
            throw CLIError.message("signed-smoke-cleanup requires CODEX_PROFILE_SIGNED_SMOKE=1")
        }
        guard let service = self.environment("CODEX_PROFILE_DATA_PROTECTION_KEYCHAIN_SERVICE"),
              !service.isEmpty,
              service.hasPrefix(self.signedSmokeServicePrefix) else {
            throw CLIError.message("signed-smoke-cleanup requires a disposable smoke Keychain service")
        }
        for profile in args {
            try self.vault.deleteAuthBlob(profileID: profile)
        }
    }

    private final class SmokeMigrationCheckpoints {
        var states: [String: AuthMigrationState]
        var fingerprints: [String: String]

        init(states: [String: AuthMigrationState] = [:], fingerprints: [String: String] = [:]) {
            self.states = states
            self.fingerprints = fingerprints
        }

        func save(profileID: String, state: AuthMigrationState, fingerprint: String?) throws {
            self.states[profileID] = state
            if state == .copiedCleanupPending {
                guard let fingerprint else { throw CLIError.message("migration smoke lost its fingerprint") }
                self.fingerprints[profileID] = fingerprint
            } else {
                self.fingerprints[profileID] = nil
            }
        }
    }

    private static func commandSignedSmokeMigration() throws {
        let legacyService = try self.signedSmokeLegacyService()
        let destination = DataProtectionKeychainAuthVault()
        let legacy = LegacyKeychainAuthVault(service: legacyService)
        let profileIDs = ["MigrationFresh", "MigrationPending"]
        defer {
            for profileID in profileIDs {
                try? destination.deleteAuthBlob(profileID: profileID)
                self.deleteLegacySmokeItem(service: legacyService, profileID: profileID)
            }
        }
        try self.runFreshMigrationSmoke(legacy: legacy, destination: destination)
        try self.runPendingMigrationSmoke(legacy: legacy, destination: destination)
        print("Signed disposable Keychain migration smoke passed.")
    }

    private static func runFreshMigrationSmoke(
        legacy: LegacyKeychainAuthVault,
        destination: DataProtectionKeychainAuthVault
    ) throws {
        let profileID = "MigrationFresh"
        let auth = self.smokeAuthData(token: "fresh")
        try self.addLegacySmokeItem(service: legacy.service, profileID: profileID, data: auth)
        let checkpoints = SmokeMigrationCheckpoints()
        let coordinator = self.smokeMigrationCoordinator(
            legacy: legacy,
            destination: destination,
            profileID: profileID,
            checkpoints: checkpoints)
        let preview = try coordinator.review()
        try coordinator.confirm(preview, approvedCount: preview.candidateCount)
        guard try legacy.loadAuthBlob(profileID: profileID) == nil,
              try destination.loadAuthBlob(profileID: profileID) == auth,
              checkpoints.states[profileID] == .complete else {
            throw CLIError.message("fresh migration smoke did not preserve the credential")
        }
        try destination.deleteAuthBlob(profileID: profileID)
    }

    private static func runPendingMigrationSmoke(
        legacy: LegacyKeychainAuthVault,
        destination: DataProtectionKeychainAuthVault
    ) throws {
        let profileID = "MigrationPending"
        let legacyAuth = self.smokeAuthData(token: "legacy")
        let refreshedAuth = self.smokeAuthData(token: "refreshed")
        try self.addLegacySmokeItem(service: legacy.service, profileID: profileID, data: legacyAuth)
        try destination.saveAuthBlob(refreshedAuth, profileID: profileID)
        let checkpoints = SmokeMigrationCheckpoints(
            states: [profileID: .copiedCleanupPending],
            fingerprints: [profileID: self.smokeFingerprint(legacyAuth)])
        let coordinator = self.smokeMigrationCoordinator(
            legacy: legacy,
            destination: destination,
            profileID: profileID,
            checkpoints: checkpoints)
        let preview = try coordinator.review()
        try coordinator.confirm(preview, approvedCount: preview.candidateCount)
        guard try legacy.loadAuthBlob(profileID: profileID) == nil,
              try destination.loadAuthBlob(profileID: profileID) == refreshedAuth,
              checkpoints.states[profileID] == .complete else {
            throw CLIError.message("pending migration smoke replaced the refreshed credential")
        }
        try destination.deleteAuthBlob(profileID: profileID)
    }

    private static func smokeMigrationCoordinator(
        legacy: LegacyKeychainAuthVault,
        destination: DataProtectionKeychainAuthVault,
        profileID: String,
        checkpoints: SmokeMigrationCheckpoints
    ) -> KeychainMigrationCoordinator {
        KeychainMigrationCoordinator(
            legacyVault: legacy,
            destination: destination,
            profiles: [ProfileConfig(id: profileID, label: profileID)],
            migrationStates: checkpoints.states,
            pendingFingerprints: checkpoints.fingerprints,
            checkpoint: { id, state, fingerprint in
                try checkpoints.save(profileID: id, state: state, fingerprint: fingerprint)
            })
    }

    private static func signedSmokeLegacyService() throws -> String {
        guard self.environment("CODEX_PROFILE_SIGNED_SMOKE") == "1",
              let destinationService = self.environment("CODEX_PROFILE_DATA_PROTECTION_KEYCHAIN_SERVICE"),
              destinationService.hasPrefix(self.signedSmokeServicePrefix),
              let legacyService = self.environment("CODEX_PROFILE_LEGACY_KEYCHAIN_SERVICE"),
              legacyService.hasPrefix(self.signedSmokeLegacyServicePrefix) else {
            throw CLIError.message("signed-smoke-migration requires disposable Keychain services")
        }
        return legacyService
    }

    private static func addLegacySmokeItem(service: String, profileID: String, data: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileID,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecValueData: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CLIError.message("could not create disposable legacy Keychain item (status \(status))")
        }
    }

    private static func deleteLegacySmokeItem(service: String, profileID: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileID,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func smokeAuthData(token: String) -> Data {
        Data("{\"OPENAI_API_KEY\":\"signed-smoke-\(token)\"}".utf8)
    }

    private static func smokeFingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct BestAuthOptions {
        var dir: String?
        var excludeCSV: String?
        var nonInteractive = false
        var json = false
        var timeout: TimeInterval = 30
    }

    private static func parseBestAuthOptions(_ args: [String]) throws -> BestAuthOptions {
        var options = BestAuthOptions()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--dir":
                guard i + 1 < args.count else {
                    throw CLIError.message("--dir requires a path argument")
                }
                i += 1
                options.dir = args[i]
            case "--exclude":
                // An explicit empty value (`--exclude ""`) is a valid no-op
                // exclusion, never a wait/prompt path. It is parsed into an
                // empty set below.
                guard i + 1 < args.count else {
                    throw CLIError.message("--exclude requires a comma-separated list")
                }
                i += 1
                options.excludeCSV = args[i]
            case "--non-interactive":
                options.nonInteractive = true
            case "--json":
                options.json = true
            case "--timeout":
                guard i + 1 < args.count,
                      let value = Double(args[i + 1]),
                      value.isFinite && value > 0 && value <= 3600 else {
                    throw CLIError.message("--timeout requires a positive number of seconds (max 3600)")
                }
                i += 1
                options.timeout = value
            default:
                throw CLIError.message("Unknown argument: \(args[i]). Usage: \(self.program) best-auth --dir <path> [--exclude <id1,id2,...>] [--json] [--non-interactive] [--timeout <seconds>]")
            }
            i += 1
        }
        return options
    }

    private static func commandBestAuth(_ args: [String]) throws {
        let options = try self.parseBestAuthOptions(args)

        guard let dir = options.dir else {
            throw CLIError.message("Usage: \(self.program) best-auth --dir <path> [--exclude <id1,id2,...>] [--json] [--non-interactive] [--timeout <seconds>]")
        }

        // Non-interactive whenever stdin is not a TTY or the caller asked.
        let interactive = self.stdinIsTTY && !options.nonInteractive

        // Watchdog guarantees the process dies even if something below blocks,
        // so callers in background shells are never stranded.
        self.armWatchdog(
            seconds: options.timeout,
            diagnostic: "best-auth timed out after \(Int(options.timeout))s; the command was unable to complete")

        let dirURL = URL(fileURLWithPath: dir).resolvingSymlinksInPath().standardizedFileURL
        let outcome = try self.performBestAuth(
            dirURL: dirURL,
            excludeIDs: self.parseExcludeIDs(options.excludeCSV),
            interactive: interactive)

        if options.json {
            let report = self.makeBestAuthReport(
                result: outcome.result,
                candidates: outcome.candidates,
                cache: outcome.cache,
                fetchedAny: outcome.fetchedAny,
                now: outcome.now)
            print(try report.jsonString())
        } else {
            print(outcome.result.profileID)
        }
    }

    /// `--exclude ""` and absent `--exclude` both parse to an empty set.
    private static func parseExcludeIDs(_ csv: String?) -> Set<String> {
        Set((csv ?? "")
            .split(separator: ",")
            .map(String.init)
            .filter { !$0.isEmpty })
    }

    private struct BestAuthOutcome {
        let result: ProfileSelector.Result
        let candidates: [ProfileCandidate]
        let cache: UsageCache
        let fetchedAny: Bool
        let now: Date
    }

    /// Shared selection core for `best-auth` and `exec`: picks the profile with
    /// the most remaining quota and writes its auth.json (0600) plus a copy of
    /// the live config.toml into `dirURL`. Failures throw the documented stable
    /// exit codes (2/3/4/6).
    private static func performBestAuth(
        dirURL: URL,
        excludeIDs: Set<String>,
        interactive: Bool
    ) throws -> BestAuthOutcome {
        let bestAuthVault = self.vault

        let config = self.configStore.loadConfig() ?? AppConfig(profiles: [], activeProfile: "")

        // Profiles-configured check is purely file-based, so exit 3 stays fast.
        if config.profiles.isEmpty {
            fputs("No profiles configured\n", stderr)
            throw CLIError.exitStatus(ExitCode.noProfilesConfigured)
        }

        var cache = self.loadCache()
        let eligibleProfiles: [ProfileConfig]
        do {
            eligibleProfiles = try config.profiles.filter { profile in
                try bestAuthVault.authBlobAvailability(profileID: profile.id) == .present
            }
        } catch {
            if self.isKeychainInteractionRequired(error) {
                self.exitKeychainInteractionRequired()
            }
            throw error
        }

        // Bound reads in non-interactive mode so a blocked storage operation
        // cannot hold an automation indefinitely.
        let readBound: TimeInterval? = interactive ? nil : 5

        // Self-fetch live usage before ranking so we never silently rank against
        // a stale/empty cache (e.g. when the menu bar app isn't running).
        let fetchResult = self.selfFetchUsage(
            profiles: eligibleProfiles,
            activeProfile: config.activeProfile,
            cache: cache,
            vault: bestAuthVault,
            readBound: readBound,
            interactive: interactive)
        cache = fetchResult.cache
        self.persistCacheMerge(cache)

        // If no live fetch succeeded and the cache has no snapshot for any
        // eligible profile, there is no usable usage data at all.
        let haveAnySnapshot = eligibleProfiles.contains { cache.snapshots[$0.id] != nil }
        if !fetchResult.fetchedAny, !haveAnySnapshot {
            if let lastError = fetchResult.lastFetchError {
                fputs("usage data unavailable (last error: \(lastError))\n", stderr)
            } else {
                fputs("usage data unavailable\n", stderr)
            }
            throw CLIError.exitStatus(ExitCode.usageDataUnavailable)
        }

        let now = Date()
        let candidates = ProfileSelector.candidates(
            profiles: eligibleProfiles,
            cache: cache,
            excludeIDs: excludeIDs,
            now: now)

        guard let result = ProfileSelector.selectBest(from: candidates) else {
            fputs("No eligible profiles available\n", stderr)
            throw CLIError.exitStatus(ExitCode.noEligibleProfile)
        }

        let authData: Data?
        do {
            switch try self.loadAuthBlobBounded(bestAuthVault, profileID: result.profileID, bound: readBound) {
            case .data(let data):
                authData = data
            case .interactionRequired:
                self.exitKeychainInteractionRequired()
            }
        } catch {
            if self.isKeychainInteractionRequired(error) {
                self.exitKeychainInteractionRequired()
            }
            throw error
        }
        guard let authData else {
            fputs("No auth data for profile '\(result.profileID)'\n", stderr)
            throw CLIError.exitStatus(1)
        }

        try self.ensurePrivateDir(dirURL)
        try AtomicFileWriter.write(authData, to: dirURL.appendingPathComponent("auth.json"))

        let liveConfig = self.paths.liveCodexHome.appendingPathComponent("config.toml")
        let destination = dirURL.appendingPathComponent("config.toml")
        try? self.fileManager.removeItem(at: destination)
        if self.fileManager.fileExists(atPath: liveConfig.path) {
            try self.fileManager.copyItem(at: liveConfig, to: destination)
        }

        return BestAuthOutcome(
            result: result,
            candidates: candidates,
            cache: cache,
            fetchedAny: fetchResult.fetchedAny,
            now: now)
    }

    private struct SelfFetchResult {
        var cache: UsageCache
        var fetchedAny: Bool
        /// Description of the last per-profile fetch error, if any failed.
        var lastFetchError: String?
    }

    /// Fetches live usage for each eligible profile (bounded concurrency 3) and
    /// merges fresh snapshots into a copy of `cache`. A per-profile failure
    /// (fetch error, or a Keychain read that needs interaction) falls back to
    /// that profile's existing cached snapshot — stale beats none — and never
    /// escalates to exit 6. Exhaustion overrides are preserved untouched.
    ///
    /// In non-interactive mode the vault is probed once: if a Keychain data read
    /// would block on a consent prompt, ALL vault reads are skipped (the live
    /// profile, read from a file, is still fetched). This avoids spawning a
    /// prompt per profile, which would otherwise stall the whole command.
    private static func selfFetchUsage(
        profiles: [ProfileConfig],
        activeProfile: String,
        cache: UsageCache,
        vault: AuthVault,
        readBound: TimeInterval?,
        interactive: Bool
    ) -> SelfFetchResult {
        guard !profiles.isEmpty else { return SelfFetchResult(cache: cache, fetchedAny: false) }

        let configURL = self.paths.liveCodexHome.appendingPathComponent("config.toml")
        let liveAuthURL = self.paths.liveAuthURL
        let version = self.version

        // One-time decision: are vault data reads usable without a prompt?
        let vaultReadable = interactive || self.vaultDataReadsAvailable(
            profiles: profiles,
            activeProfile: activeProfile,
            vault: vault,
            bound: readBound)

        let fetchOutcome = self.runBlocking { () -> (snapshots: [String: UsageSnapshot], lastError: String?) in
            await withTaskGroup(of: (String, UsageSnapshot?, String?).self) { group in
                var pending = profiles[...]
                var inFlight = 0
                var results: [String: UsageSnapshot] = [:]
                var lastError: String?

                func authData(for id: String) -> Data? {
                    if id == activeProfile,
                       FileManager.default.fileExists(atPath: liveAuthURL.path) {
                        return try? Data(contentsOf: liveAuthURL)
                    }
                    guard vaultReadable else { return nil }
                    switch try? self.loadAuthBlobBounded(vault, profileID: id, bound: readBound) {
                    case .data(let data): return data
                    default: return nil
                    }
                }

                func enqueueNext() {
                    guard let profile = pending.popFirst() else { return }
                    inFlight += 1
                    let id = profile.id
                    let data = authData(for: id)
                    group.addTask {
                        guard let data else { return (id, nil, nil) }
                        do {
                            let snapshot = try await CLIUsageFetcher.fetch(
                                profileId: id,
                                authData: data,
                                codexConfigURL: configURL,
                                clientVersion: version)
                            return (id, snapshot, nil)
                        } catch {
                            return (id, nil, error.localizedDescription)
                        }
                    }
                }

                for _ in 0 ..< min(3, profiles.count) { enqueueNext() }
                while inFlight > 0 {
                    if let (id, snapshot, fetchError) = await group.next() {
                        inFlight -= 1
                        if let snapshot { results[id] = snapshot }
                        if let fetchError { lastError = fetchError }
                        enqueueNext()
                    }
                }
                return (results, lastError)
            }
        }

        var merged = cache
        for (id, snapshot) in fetchOutcome.snapshots {
            merged.snapshots[id] = snapshot
        }
        return SelfFetchResult(
            cache: merged,
            fetchedAny: !fetchOutcome.snapshots.isEmpty,
            lastFetchError: fetchOutcome.lastError)
    }

    /// Probes whether vault data reads return without a consent prompt, using a
    /// single bounded read against the first non-live profile. Returns false if
    /// that read blocks (prompt up) so the caller skips all vault reads. A
    /// timed-out probe leaves one blocked thread holding a prompt; the process
    /// exits shortly after, dismissing it.
    private static func vaultDataReadsAvailable(
        profiles: [ProfileConfig],
        activeProfile: String,
        vault: AuthVault,
        bound: TimeInterval?
    ) -> Bool {
        guard let probe = profiles.first(where: { $0.id != activeProfile }) else { return true }
        switch try? self.loadAuthBlobBounded(vault, profileID: probe.id, bound: bound) {
        case .interactionRequired: return false
        default: return true
        }
    }

    /// Runs an async closure to completion from synchronous CLI code.
    private static func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    /// Writes the merged cache using the same atomic-write + override-preserving
    /// semantics the app and `mark-exhausted` use. Best-effort: a write failure
    /// must not fail the command (the selection is still valid).
    private static func persistCacheMerge(_ cache: UsageCache) {
        // Hold the cache lock across the disk re-read and the write so a lease
        // (or override) a concurrent process commits in this window is not
        // dropped by this whole-cache replace. Best-effort: a lock/write failure
        // must not fail the command (the selection is still valid).
        try? self.withCacheLock {
            // Preserve any overrides already on disk that aren't in our copy.
            let toWrite = cache.mergingDiskOverrides(
                fromCacheAt: self.paths.cacheURL,
                decoder: JSONDecoder.iso8601Decoder())
            try self.saveCache(toWrite)
        }
    }

    private static func makeBestAuthReport(
        result: ProfileSelector.Result,
        candidates: [ProfileCandidate],
        cache: UsageCache,
        fetchedAny: Bool,
        now: Date = Date()
    ) -> BestAuthReport {
        let candidateReports = candidates
            .sorted { $0.profileID < $1.profileID }
            .map { candidate -> BestAuthReport.Candidate in
                let age = cache.snapshots[candidate.profileID].map {
                    Int(now.timeIntervalSince($0.fetchedAt).rounded())
                }
                return BestAuthReport.Candidate(
                    id: candidate.profileID,
                    tier: candidate.tier.reportName,
                    score: candidate.effectiveScore,
                    snapshotAgeSeconds: age)
            }
        return BestAuthReport(
            selected: result.profileID,
            tier: result.tier.reportName,
            score: result.effectiveScore,
            candidates: candidateReports,
            fetched: fetchedAny)
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

        try self.markProfileExhausted(profile, until: blockedUntil, source: "codex_exec")
        self.note("Marked '\(profile)' exhausted until \(ISO8601DateFormatter().string(from: blockedUntil))")
    }

    private static func markProfileExhausted(_ profile: String, until blockedUntil: Date, source: String) throws {
        try self.withCacheLock {
            var cache = self.loadCache()
            cache.exhaustionOverrides[profile] = ExhaustionOverride(
                blockedUntil: blockedUntil,
                reason: "rate_limit",
                source: source)
            // Merge-on-write like the lease writers: re-read disk so a concurrent
            // process's lease reservation (or another profile's override) committed
            // between our load and save is preserved. `excluding: profile` keeps our
            // new override authoritative for this profile. The lock makes the
            // re-read + write one isolated transaction.
            let toWrite = cache.mergingDiskOverrides(
                fromCacheAt: self.paths.cacheURL,
                excluding: profile,
                decoder: JSONDecoder.iso8601Decoder())
            try self.saveCache(toWrite)
        }
    }

    private static func commandImportAuth(_ args: [String]) throws {
        var dir: String?
        var profile: String?
        var nonInteractive = false
        var timeout: TimeInterval = 30
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
            case "--non-interactive":
                nonInteractive = true
            case "--timeout":
                guard i + 1 < args.count,
                      let value = Double(args[i + 1]),
                      value.isFinite && value > 0 && value <= 3600 else {
                    throw CLIError.message("--timeout requires a positive number of seconds (max 3600)")
                }
                i += 1
                timeout = value
            default:
                throw CLIError.message("Unknown argument: \(args[i])")
            }
            i += 1
        }

        guard let dir, let profile else {
            throw CLIError.message("Usage: \(self.program) import-auth --dir <path> --profile <id> [--non-interactive] [--timeout <seconds>]")
        }
        try self.validateProfile(profile)

        // Non-interactive whenever stdin is not a TTY or the caller asked.
        let interactive = self.stdinIsTTY && !nonInteractive

        if !interactive {
            self.armWatchdog(
                seconds: timeout,
                diagnostic: "import-auth timed out after \(Int(timeout))s")
        }

        try self.importRefreshedAuth(
            dirURL: URL(fileURLWithPath: dir).resolvingSymlinksInPath().standardizedFileURL,
            profile: profile,
            vault: self.vault)
    }

    /// Write-back core shared by `import-auth` and `exec`: saves `dirURL`'s
    /// auth.json over the stored credential for `profile`, but only when it
    /// validates and its identity fingerprint matches the stored one. Callers
    /// without a vault preference get the selected primary vault.
    private static func importRefreshedAuth(dirURL: URL, profile: String) throws {
        try self.importRefreshedAuth(dirURL: dirURL, profile: profile, vault: self.vault)
    }

    /// Classifies a write-back failure for the gc reclaim path: `true` when the
    /// leased home holds a real credential that would be LOST by deleting it, so
    /// the home must be preserved for a retry; `false` when there is nothing
    /// recoverable to lose (so the home can be reclaimed). importRefreshedAuth
    /// signals "nothing to write back" exclusively with exit 1 (missing home
    /// auth, no such profile, or an invalid/garbage blob) and the dangerous
    /// "home holds a valid but different-identity credential" case with exit 5.
    /// Any non-CLIError (e.g. a vault save failure) is treated as recoverable —
    /// the credential is intact and the write merely failed to land.
    private static func isRecoverableWritebackError(_ error: Error) -> Bool {
        switch error {
        case CLIError.exitStatus(1):
            return false
        case CLIError.exitStatus:
            return true  // exit 5 identity mismatch: a real credential is at risk
        default:
            return true  // vault/save error: credential intact, write didn't land
        }
    }

    private static func importRefreshedAuth(dirURL: URL, profile: String, vault: AuthVault) throws {
        let authURL = dirURL.appendingPathComponent("auth.json")
        guard let updatedData = try? Data(contentsOf: authURL) else {
            fputs("No auth data found at \(authURL.path)\n", stderr)
            throw CLIError.exitStatus(1)
        }
        guard let existingData = try vault.loadAuthBlob(profileID: profile) else {
            fputs("No existing auth data for profile '\(profile)'\n", stderr)
            throw CLIError.exitStatus(1)
        }
        guard updatedData != existingData else { return }
        guard AuthBlob.isPlausibleAuthBlob(updatedData) else {
            fputs("Warning: temp auth.json failed validation - preserving existing credential\n", stderr)
            throw CLIError.exitStatus(1)
        }

        do {
            _ = try AuthBlob.load(from: updatedData)
        } catch {
            fputs("Warning: temp auth.json has invalid token structure - preserving existing credential\n", stderr)
            throw CLIError.exitStatus(1)
        }

        let existingFingerprint = AuthBlob.identityFingerprint(from: existingData)
        let updatedFingerprint = AuthBlob.identityFingerprint(from: updatedData)
        guard let existingFingerprint, let updatedFingerprint else {
            fputs("Warning: temp auth.json identity could not be verified - preserving existing credential\n", stderr)
            throw CLIError.exitStatus(1)
        }
        if existingFingerprint != updatedFingerprint {
            // Identity mismatch is the one case external rotation tooling must
            // distinguish: the refreshed credential belongs to a different
            // account. Exit 5 is reserved exclusively for this.
            fputs("Warning: temp auth.json has different identity - preserving existing credential\n", stderr)
            throw CLIError.exitStatus(ExitCode.identityMismatch)
        }

        try vault.saveAuthBlob(updatedData, profileID: profile)
    }

    private struct ExecOptions {
        var maxAttempts = 3
        var excludeCSV: String?
        // Selection fetches live usage for every profile; with many profiles
        // that routinely takes 15-20s, so exec defaults higher than best-auth.
        var timeout: TimeInterval = 60
        var command: [String] = []
    }

    private static var execUsage: String {
        "Usage: \(self.program) exec [--max-attempts <n>] [--exclude <id1,id2,...>] [--timeout <seconds>] -- <command> [args...]"
    }

    private static func parseExecOptions(_ args: [String]) throws -> ExecOptions {
        var options = ExecOptions()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--":
                options.command = Array(args[(i + 1)...])
                guard !options.command.isEmpty else {
                    throw CLIError.message(self.execUsage)
                }
                return options
            case "--max-attempts":
                guard i + 1 < args.count,
                      let value = Int(args[i + 1]),
                      (1 ... 20).contains(value) else {
                    throw CLIError.message("--max-attempts requires a number between 1 and 20")
                }
                i += 1
                options.maxAttempts = value
            case "--exclude":
                guard i + 1 < args.count else {
                    throw CLIError.message("--exclude requires a comma-separated list")
                }
                i += 1
                options.excludeCSV = args[i]
            case "--timeout":
                guard i + 1 < args.count,
                      let value = Double(args[i + 1]),
                      value.isFinite && value > 0 && value <= 3600 else {
                    throw CLIError.message("--timeout requires a positive number of seconds (max 3600)")
                }
                i += 1
                options.timeout = value
            default:
                throw CLIError.message("Unknown argument: \(args[i]). \(self.execUsage)")
            }
            i += 1
        }
        throw CLIError.message(self.execUsage)
    }

    /// Runs an arbitrary command with CODEX_HOME pointed at the best profile's
    /// credentials, rotating to the next best profile when the command fails
    /// with a usage-limit error. The live ~/.codex is never touched; each
    /// attempt gets a private temp home that is imported back (token refresh)
    /// and deleted afterwards.
    private static func commandExec(_ args: [String]) throws {
        let options = try self.parseExecOptions(args)

        // stdin is routinely a pipe here (`exec -- codex exec - < prompt`), so
        // interactivity is judged by stderr: a TTY there means a human is
        // watching and can answer a Keychain consent prompt.
        let interactive = isatty(2) != 0

        var excludeIDs = self.parseExcludeIDs(options.excludeCSV)
        var attempt = 1
        while true {
            let tempHome = try self.makeTempHome(profile: "exec")
            // Per-iteration defer: the temp home holds a live credential, so it
            // must be removed on EVERY exit from this iteration — success,
            // rotation, or any throw (including runChild failures).
            defer { try? self.fileManager.removeItem(at: tempHome) }
            let profile: String
            do {
                // The watchdog only covers profile selection; it is disarmed
                // before the child runs so long-running commands are safe.
                let disarm = self.armWatchdog(
                    seconds: options.timeout,
                    diagnostic: "exec: profile selection timed out after \(Int(options.timeout))s")
                defer { disarm() }
                profile = try self.performBestAuth(
                    dirURL: tempHome,
                    excludeIDs: excludeIDs,
                    interactive: interactive).result.profileID
            } catch {
                if attempt > 1 {
                    fputs("[codex-profile] no further profiles available after \(attempt - 1) usage-limited attempt(s)\n", stderr)
                }
                throw error
            }

            fputs("[codex-profile] attempt \(attempt)/\(options.maxAttempts): running with profile '\(profile)'\n", stderr)
            let child = try self.runChild(command: options.command, codexHome: tempHome)
            try? self.importRefreshedAuth(dirURL: tempHome, profile: profile)

            if child.status == 0 { return }
            guard Self.looksRateLimited(child.stderrTail) else {
                throw CLIError.exitStatus(child.status)
            }

            try? self.markProfileExhausted(profile, until: Date().addingTimeInterval(3600), source: "exec")
            excludeIDs.insert(profile)
            guard attempt < options.maxAttempts else {
                fputs("[codex-profile] usage limit hit on \(options.maxAttempts) profile(s); giving up. Wait for a limit reset or add another profile.\n", stderr)
                throw CLIError.exitStatus(child.status)
            }
            fputs("[codex-profile] profile '\(profile)' hit a usage limit; marked exhausted, rotating\n", stderr)
            attempt += 1
        }
    }

    private struct ChildResult {
        let status: Int32
        let stderrTail: String
    }

    /// Runs the wrapped command with CODEX_HOME set to `codexHome`. stdin and
    /// stdout are inherited untouched so prompts pipe in and output streams
    /// out; stderr is teed — passed through live AND captured (bounded) for
    /// usage-limit detection. SIGINT/SIGTERM are forwarded to the child so the
    /// wrapper can still clean up its temp home.
    private static func runChild(command: [String], codexHome: URL) throws -> ChildResult {
        let name = command[0]
        let resolved: String
        if name.contains("/") {
            resolved = name
        } else if let found = self.which(name) {
            resolved = found
        } else {
            throw CLIError.message("Command not found on PATH: \(name)")
        }
        guard self.fileManager.isExecutableFile(atPath: resolved) else {
            throw CLIError.message("Command not executable: \(resolved)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = Array(command.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome.path
        env["PATH"] = self.effectivePATH()
        process.environment = env

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let tail = BoundedBuffer(limit: 256 * 1024)
        let drained = DispatchSemaphore(value: 0)
        let reader = Thread {
            let handle = stderrPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                tail.append(data)
                try? FileHandle.standardError.write(contentsOf: data)
            }
            drained.signal()
        }
        reader.stackSize = 512 * 1024

        // Handlers go in before run(): they no-op while execChildPID == 0, so
        // a signal in the spawn window is absorbed instead of killing the
        // wrapper before it can clean up.
        signal(SIGINT, execForwardSignal)
        signal(SIGTERM, execForwardSignal)
        do {
            try process.run()
        } catch {
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
            throw error
        }
        execChildPID = process.processIdentifier
        reader.start()
        process.waitUntilExit()
        drained.wait()
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        execChildPID = 0

        let status: Int32
        if process.terminationReason == .uncaughtSignal {
            status = 128 + process.terminationStatus
        } else {
            status = process.terminationStatus
        }
        return ChildResult(status: status, stderrTail: tail.string)
    }

    /// Bounded byte buffer keeping only the most recent `limit` bytes.
    private final class BoundedBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var data = Data()

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            self.lock.lock()
            self.data.append(chunk)
            if self.data.count > self.limit {
                self.data.removeFirst(self.data.count - self.limit)
            }
            self.lock.unlock()
        }

        var string: String {
            self.lock.lock()
            defer { self.lock.unlock() }
            return String(decoding: self.data, as: UTF8.self)
        }
    }

    /// Heuristic over the child's stderr for retryable usage-limit failures.
    /// Only consulted after the child exited non-zero, so these phrases in
    /// successful output can never trigger a rotation.
    private static func looksRateLimited(_ stderrText: String) -> Bool {
        let plain = self.strippingANSI(stderrText).lowercased()
        if plain.contains("rate limit") || plain.contains("rate_limit")
            || plain.contains("usage limit") || plain.contains("quota exceeded")
            || plain.contains("too many requests") {
            return true
        }
        return plain.range(of: #"\b429\b"#, options: .regularExpression) != nil
    }

    private static func strippingANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\u{1B}\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression)
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

    private static func findCodexCLI() throws -> String {
        if let override = self.environment("CODEX_CLI"), !override.isEmpty {
            guard self.fileManager.isExecutableFile(atPath: override) else {
                throw CLIError.message("CODEX_CLI is set but not executable: \(override)")
            }
            return override
        }
        if let bundled = try? CodexDesktopLifecycle().resolveBundledCLI() {
            return bundled
        }
        if let path = self.which("codex") {
            return path
        }
        throw CLIError.message("Codex CLI not found. Install Codex or set CODEX_CLI=/path/to/codex.")
    }

    private static func codexAppBinary() throws -> String {
        if let override = self.environment("CODEX_APP_BIN") {
            guard self.fileManager.isExecutableFile(atPath: override) else {
                throw CLIError.message("Codex Desktop binary not found at \(override)")
            }
            return override
        }
        guard let executable = try CodexDesktopLifecycle().resolveInstallation().executablePath else {
            throw CLIError.message("Codex Desktop binary not found")
        }
        return executable
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

    /// Runs `body` while holding the cross-process cache lock, so a read of the
    /// cache and the matching write form ONE isolated transaction. Every
    /// whole-cache mutator (lease commands, mark-exhausted, persistCacheMerge)
    /// must funnel through this — otherwise a concurrent writer can drop the
    /// delta committed inside `body` (see CacheLock).
    private static func withCacheLock<T>(_ body: () throws -> T) throws -> T {
        try CacheLock.withLock(at: self.paths.cacheLockURL, fileManager: self.fileManager, body)
    }

    // MARK: - Lease reservation

    /// Known root under the switcher home so `lease gc` can find and reclaim an
    /// orphaned home after a crash (unlike an untracked mktemp directory).
    private static var leasesRoot: URL {
        self.paths.switcherHome.appendingPathComponent("leases", isDirectory: true)
    }

    /// Defense-in-depth before any recursive delete of a cache-recorded home:
    /// require the path to be an immediate child of `leasesRoot` whose directory
    /// name is exactly the lease token. A malformed/legacy cache entry pointing
    /// elsewhere is skipped (and warned) rather than blindly `rm`'d.
    private static func isLeaseHome(_ path: String, token: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let expected = self.leasesRoot.appendingPathComponent(token, isDirectory: true).standardizedFileURL
        guard url.path == expected.path else {
            fputs("[lease] refusing to remove unexpected home path '\(path)' (token \(token))\n", stderr)
            return false
        }
        return true
    }

    /// Reconciles the cache with disk (disk-authoritative leases) and returns a
    /// copy onto which a lease delta can be applied before saving. Reading disk
    /// here is what makes the lease helpers' read-modify-write window tiny.
    private static func reconciledCache() -> UsageCache {
        self.loadCache().mergingDiskOverrides(
            fromCacheAt: self.paths.cacheURL,
            decoder: JSONDecoder.iso8601Decoder())
    }

    /// Records (or replaces) the reservation for `profileID` on top of the
    /// disk-authoritative lease map, so no concurrently-written lease is lost.
    private static func upsertLease(profileID: String, reservation: LeaseReservation) throws {
        try self.withCacheLock {
            var cache = self.reconciledCache()
            cache.leases[profileID] = reservation
            try self.saveCache(cache)
        }
    }

    /// Atomically claims `profileID` for a fresh `begin`. Because `begin` reads
    /// the active-lease exclusion set BEFORE its multi-second select+seed, two
    /// concurrent begins can both pick the same best profile and both reach
    /// `upsertLease`, where the later one would silently overwrite the earlier
    /// reservation (orphaning the earlier process's live credential). This
    /// re-checks UNDER the lock: if a DIFFERENT lease still HOLDS the profile,
    /// the claim loses and throws — the caller deletes its seeded home.
    ///
    /// We refuse on ANY recorded different-token lease, not just an *active* one.
    /// An expired-but-still-recorded lease means `gc` could not clear it — which
    /// for a lease only happens when its write-back FAILED and `gc`/`end`
    /// deliberately preserved its home pending credential recovery. Overwriting
    /// that reservation would orphan the home and lose the preserved credential.
    /// `begin` runs an opportunistic `gc` first, so a cleanly-removable expired
    /// lease is already gone by the time we get here; anything left is protected.
    /// A lease already carrying our own token (a retry) or an absent slot is fine.
    private static func claimLease(profileID: String, reservation: LeaseReservation) throws {
        try self.withCacheLock {
            var cache = self.reconciledCache()
            if let existing = cache.leases[profileID],
               existing.token != reservation.token {
                throw CLIError.message(
                    "lease begin: profile \(profileID) is reserved by another run (or holds a credential pending recovery); retry")
            }
            cache.leases[profileID] = reservation
            try self.saveCache(cache)
        }
    }

    /// Drops the reservation for `profileID` — but only if it still carries
    /// `expectedToken` (compare-and-delete). This prevents `gc`/`end` from
    /// deleting a FRESH lease that a concurrent `begin` placed on the same
    /// profile after the one we meant to remove. `nil` token = unconditional.
    private static func removeLease(profileID: String, expectedToken: String? = nil) throws {
        try self.withCacheLock {
            var cache = self.reconciledCache()
            if let expectedToken, cache.leases[profileID]?.token != expectedToken {
                return  // a concurrent writer replaced this lease; leave theirs intact
            }
            cache.leases.removeValue(forKey: profileID)
            try self.saveCache(cache)
        }
    }

    /// Atomically moves a reservation from `oldProfileID` to `newProfileID` in a
    /// single disk-authoritative write, so the lease is never transiently absent.
    /// The old key is removed only if it still carries our token, and the move
    /// refuses to clobber a DIFFERENT concurrent lease already on the destination.
    private static func moveLease(
        from oldProfileID: String,
        to newProfileID: String,
        reservation: LeaseReservation
    ) throws {
        try self.withCacheLock {
            var cache = self.reconciledCache()
            // The source key must STILL carry our token. If a concurrent `end`
            // or `gc` removed this lease on disk while swap was selecting, the
            // lease no longer exists — writing the destination would RESURRECT
            // an ended lease (invariant: never resurrect). Abort instead.
            guard cache.leases[oldProfileID]?.token == reservation.token else {
                throw CLIError.message(
                    "lease swap: lease \(reservation.token) was ended or reclaimed concurrently; not resurrecting it")
            }
            cache.leases.removeValue(forKey: oldProfileID)
            if let existing = cache.leases[newProfileID], existing.token != reservation.token {
                throw CLIError.message(
                    "lease swap: destination profile \(newProfileID) is already leased by another run")
            }
            cache.leases[newProfileID] = reservation
            try self.saveCache(cache)
        }
    }

    /// Finds the lease record for a token by scanning the cache. Returns the
    /// profile ID it is currently bound to and the reservation, or nil if no
    /// such lease exists (already ended / never created).
    private static func findLease(token: String) -> (profileID: String, reservation: LeaseReservation)? {
        for (profileID, reservation) in self.loadCache().leases where reservation.token == token {
            return (profileID, reservation)
        }
        return nil
    }

    private static func commandLease(_ args: [String]) throws {
        guard let sub = args.first else {
            throw CLIError.message("Usage: \(self.program) lease <begin|swap|end|gc> [options]")
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "begin": try self.commandLeaseBegin(rest)
        case "swap":  try self.commandLeaseSwap(rest)
        case "end":   try self.commandLeaseEnd(rest)
        case "gc":    try self.commandLeaseGC(rest)
        default:
            throw CLIError.message("Unknown lease subcommand: \(sub). Expected begin, swap, end, or gc")
        }
    }

    private struct LeaseBeginOptions {
        var excludeCSV: String?
        var nonInteractive = false
        var json = false
        var timeout: TimeInterval = 60
        // Default TTL is the crash-recovery horizon, NOT an expected run length:
        // a lease is normally released by `lease end`, and gc-by-expiry only
        // reclaims a home whose owner died without cleaning up. 1h comfortably
        // exceeds the longest realistic single review, so a slow-but-alive run
        // is never reclaimed out from under itself.
        var ttl: TimeInterval = 3600
    }

    private static func parseLeaseBeginOptions(_ args: [String]) throws -> LeaseBeginOptions {
        var options = LeaseBeginOptions()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--exclude":
                guard i + 1 < args.count else {
                    throw CLIError.message("--exclude requires a comma-separated list")
                }
                i += 1
                options.excludeCSV = args[i]
            case "--non-interactive":
                options.nonInteractive = true
            case "--json":
                options.json = true
            case "--timeout":
                guard i + 1 < args.count,
                      let value = Double(args[i + 1]),
                      value.isFinite && value > 0 && value <= 3600 else {
                    throw CLIError.message("--timeout requires a positive number of seconds (max 3600)")
                }
                i += 1
                options.timeout = value
            case "--ttl":
                guard i + 1 < args.count,
                      let value = Double(args[i + 1]),
                      value.isFinite && value > 0 && value <= 86400 else {
                    throw CLIError.message("--ttl requires a positive number of seconds (max 86400)")
                }
                i += 1
                options.ttl = value
            default:
                throw CLIError.message("Unknown argument: \(args[i]). Usage: \(self.program) lease begin [--exclude <id1,id2,...>] [--ttl <seconds>] [--timeout <seconds>] [--json] [--non-interactive]")
            }
            i += 1
        }
        return options
    }

    /// JSON output shape for `lease begin --json`.
    private struct LeaseBeginReport: Codable {
        let profile: String
        let home: String
        let token: String
        let expiresAt: Date

        enum CodingKeys: String, CodingKey {
            case profile, home, token
            case expiresAt = "expires_at"
        }
    }

    private static func commandLeaseBegin(_ args: [String]) throws {
        let options = try self.parseLeaseBeginOptions(args)

        // Non-interactive whenever stdin is not a TTY or the caller asked.
        let interactive = self.stdinIsTTY && !options.nonInteractive

        // Opportunistic cleanup of expired homes — best-effort; never fail begin.
        try? self.commandLeaseGC([])

        // Watchdog guarantees the process dies even if selection blocks; disarm
        // on the way out so a begin that finishes near the timeout boundary is
        // never killed after it has already succeeded.
        let disarmWatchdog = self.armWatchdog(
            seconds: options.timeout,
            diagnostic: "lease begin timed out after \(Int(options.timeout))s")
        defer { disarmWatchdog() }

        // Exclude any profile holding an active lease so two concurrent runs
        // never reserve the same account.
        let now = Date()
        var exclusion = self.parseExcludeIDs(options.excludeCSV)
        for (profileID, lease) in self.loadCache().leases where lease.isActive(now: now) {
            exclusion.insert(profileID)
        }

        let token = UUID().uuidString
        let home = self.leasesRoot.appendingPathComponent(token, isDirectory: true)
        try self.ensurePrivateDir(self.leasesRoot)
        try self.ensurePrivateDir(home)

        // Everything from here until the reservation is committed seeds a LIVE
        // credential into `home`. Any failure before/including `upsertLease`
        // must remove that home so a live credential is never left untracked.
        let profile: String
        let reservation: LeaseReservation
        do {
            let outcome = try self.performBestAuth(
                dirURL: home,
                excludeIDs: exclusion,
                interactive: interactive)
            profile = outcome.result.profileID
            // Start the TTL clock AFTER the (multi-second) selection+seed, not
            // from `now` above, so a tiny --ttl can't leave the lease born expired.
            let sealedAt = Date()
            reservation = LeaseReservation(
                token: token,
                home: home.path,
                expiresAt: sealedAt.addingTimeInterval(options.ttl),
                createdAt: now)
            try self.claimLease(profileID: profile, reservation: reservation)
        } catch {
            try? self.fileManager.removeItem(at: home)
            throw error
        }

        if options.json {
            let report = LeaseBeginReport(
                profile: profile,
                home: home.path,
                token: token,
                expiresAt: reservation.expiresAt)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print(home.path)
        }
    }

    /// Best-effort: removes expired lease homes and reclaims any home directory
    /// under `leasesRoot` whose token is not an active lease (e.g. left by a
    /// crashed process). Never throws on a single removal failure.
    private static func commandLeaseGC(_ args: [String]) throws {
        if let unknown = args.first {
            throw CLIError.message("Unknown argument: \(unknown). Usage: \(self.program) lease gc")
        }
        let now = Date()

        // Reclaim homes whose reservation has expired, then drop the reservation
        // — but only if the lease still carries that token (compare-and-delete),
        // so a fresh lease a concurrent `begin` just placed on the same profile
        // is never dropped. Only remove a home that is actually under leasesRoot.
        //
        // Credential-safety: an expired lease's home may still hold the ONLY copy
        // of a refreshed credential — most importantly one that `lease end`
        // deliberately PRESERVED after a write-back failure. So attempt write-back
        // here before deleting, and on failure keep the home + reservation for a
        // later retry rather than destroying the credential. We always have the
        // bound profile (the lease's map key), so the write-back target is known.
        let gcVault = self.vault
        for (profileID, lease) in self.loadCache().leases where !lease.isActive(now: now) {
            var writebackFailed = false
            if self.isLeaseHome(lease.home, token: lease.token) {
                do {
                    try self.importRefreshedAuth(
                        dirURL: URL(fileURLWithPath: lease.home),
                        profile: profileID,
                        vault: gcVault)
                } catch {
                    // Preserve ONLY when the failure means a real credential
                    // would be lost (see isRecoverableWritebackError): an identity
                    // mismatch (the home holds a valid but different-identity
                    // credential) or a genuine vault save error. The non-
                    // recoverable cases — no home auth.json, no such profile in
                    // the vault, or an invalid blob — have nothing to write back,
                    // so the home must still be reclaimed or it would leak forever.
                    if self.isRecoverableWritebackError(error) {
                        fputs("[lease gc] write-back FAILED for expired lease on '\(profileID)': \(error). "
                            + "Preserving the home for recovery; will retry on the next gc.\n", stderr)
                        writebackFailed = true
                    } else {
                        fputs("[lease gc] nothing to write back for expired lease on '\(profileID)' (\(error)); reclaiming the home.\n", stderr)
                    }
                }
                if !writebackFailed {
                    try? self.fileManager.removeItem(atPath: lease.home)
                }
            }
            if !writebackFailed {
                try? self.removeLease(profileID: profileID, expectedToken: lease.token)
            }
        }

        // Orphan sweep: remove any lease home dir whose token is not a RECORDED
        // lease. Recompute from the freshly-written cache so a reservation
        // removed above is not treated as still present.
        //
        // We protect EVERY recorded token, not just active ones: the expired
        // loop above deliberately PRESERVES an expired lease (home + reservation)
        // when its write-back failed, because that home may hold the only copy of
        // a refreshed credential. If the sweep deleted homes for expired-but-
        // recorded leases, it would destroy exactly that preserved credential
        // after the 300s grace window. A truly orphaned home (crashed begin, no
        // reservation at all) has no recorded token and is still reclaimed here.
        guard self.fileManager.fileExists(atPath: self.leasesRoot.path),
              let entries = try? self.fileManager.contentsOfDirectory(
                  at: self.leasesRoot,
                  includingPropertiesForKeys: nil) else { return }
        let recordedTokens = Set(self.loadCache().leases.map { _, lease in lease.token })
        // Never reclaim a home modified within the grace window: it may belong
        // to a CONCURRENT `lease begin` that has seeded the home but not yet
        // recorded its reservation (the select+seed window is ~15-20s). Without
        // this, one run's opportunistic gc would delete another run's in-flight
        // live-credential home and break it.
        let orphanGrace: TimeInterval = 300
        let cutoff = now.addingTimeInterval(-orphanGrace)
        for entry in entries {
            var isDir: ObjCBool = false
            guard self.fileManager.fileExists(atPath: entry.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            if recordedTokens.contains(entry.lastPathComponent) { continue }
            if let attrs = try? self.fileManager.attributesOfItem(atPath: entry.path),
               let mtime = attrs[.modificationDate] as? Date, mtime > cutoff {
                continue
            }
            try? self.fileManager.removeItem(at: entry)
        }
    }

    private struct LeaseSwapOptions {
        var token: String?
        var excludeCSV: String?
        var nonInteractive = false
        var json = false
        var timeout: TimeInterval = 60
        // TTL refreshes on swap: the rotation resets the crash-recovery horizon
        // from the moment the fresh credential is seeded. Matches `begin`'s 1h
        // default so a swapped run is never reclaimed on a shorter clock.
        var ttl: TimeInterval = 3600
    }

    private static func parseLeaseSwapOptions(_ args: [String]) throws -> LeaseSwapOptions {
        var options = LeaseSwapOptions()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--exclude":
                guard i + 1 < args.count else {
                    throw CLIError.message("--exclude requires a comma-separated list")
                }
                i += 1
                options.excludeCSV = args[i]
            case "--timeout":
                guard i + 1 < args.count,
                      let value = Double(args[i + 1]),
                      value.isFinite && value > 0 && value <= 3600 else {
                    throw CLIError.message("--timeout requires a positive number of seconds (max 3600)")
                }
                i += 1
                options.timeout = value
            case "--ttl":
                guard i + 1 < args.count,
                      let value = Double(args[i + 1]),
                      value.isFinite && value > 0 && value <= 86400 else {
                    throw CLIError.message("--ttl requires a positive number of seconds (max 86400)")
                }
                i += 1
                options.ttl = value
            case "--non-interactive":
                options.nonInteractive = true
            case "--json":
                options.json = true
            default:
                if args[i].hasPrefix("-") {
                    throw CLIError.message("Unknown argument: \(args[i]). Usage: \(self.program) lease swap <token> [--exclude <id1,id2,...>] [--ttl <seconds>] [--timeout <seconds>] [--json] [--non-interactive]")
                }
                guard options.token == nil else {
                    throw CLIError.message("Unexpected extra argument: \(args[i])")
                }
                options.token = args[i]
            }
            i += 1
        }
        return options
    }

    /// JSON output shape for `lease swap --json`.
    private struct LeaseSwapReport: Codable {
        let profile: String
        let home: String
    }

    /// Rotates the lease's credential to a fresh account inside the SAME warm
    /// home when the current account hits a usage limit. `performBestAuth`
    /// overwrites only auth.json + config.toml in place; the warm session's
    /// `sessions/` is never touched. The reservation moves to the new profile
    /// under the same token. A failure after the rewrite propagates — the home
    /// still holds a valid credential, and the caller cleans up via `lease end`.
    private static func commandLeaseSwap(_ args: [String]) throws {
        let options = try self.parseLeaseSwapOptions(args)
        guard let token = options.token else {
            throw CLIError.message("Usage: \(self.program) lease swap <token> [--exclude <id1,id2,...>] [--ttl <seconds>] [--timeout <seconds>] [--json] [--non-interactive]")
        }

        guard let (oldProfile, reservation) = self.findLease(token: token) else {
            throw CLIError.message("No active lease for token \(token)")
        }

        let home = URL(fileURLWithPath: reservation.home)
        let interactive = self.stdinIsTTY && !options.nonInteractive

        // Disarm on the way out so a swap that finishes near the timeout boundary
        // is never killed after it has already succeeded.
        let disarmWatchdog = self.armWatchdog(
            seconds: options.timeout,
            diagnostic: "lease swap timed out after \(Int(options.timeout))s")
        defer { disarmWatchdog() }

        // Credential-safety: the warm session may have REFRESHED the old
        // account's token in `home`, which is the ONLY copy (the vault still has
        // the pre-session credential). `performBestAuth` below overwrites
        // home/auth.json in place, so we must write the old account's refreshed
        // credential back to its profile FIRST. If write-back fails, abort the
        // swap and preserve the home — overwriting would silently lose the
        // refresh. (importRefreshedAuth is a no-op when nothing changed, and
        // refuses to write a different identity, so this is safe to always run.)
        do {
            try self.importRefreshedAuth(dirURL: home, profile: oldProfile, vault: self.vault)
        } catch {
            fputs("[lease swap] write-back of the current account '\(oldProfile)' FAILED: \(error). "
                + "Aborting swap and preserving the leased home so the refreshed credential is not lost "
                + "(retry, or let gc/end reclaim after the TTL).\n", stderr)
            throw error
        }

        // Stop re-picking the account we are rotating away from.
        try? self.markProfileExhausted(oldProfile, until: Date().addingTimeInterval(3600), source: "lease")

        let now = Date()
        var exclusion = self.parseExcludeIDs(options.excludeCSV)
        for (profileID, lease) in self.loadCache().leases where lease.isActive(now: now) {
            exclusion.insert(profileID)
        }
        exclusion.insert(oldProfile)

        // In-place hot-swap inside the existing home.
        let outcome = try self.performBestAuth(
            dirURL: home,
            excludeIDs: exclusion,
            interactive: interactive)
        let newProfile = outcome.result.profileID

        // Move the reservation to the new profile in ONE cache write (same
        // token + home, fresh TTL started after the re-seed), so the lease is
        // never transiently absent.
        //
        // Ordering hazard: `performBestAuth` already overwrote the home with
        // `newProfile`'s credential, but `moveLease` can still legitimately fail
        // — the source lease was ended/reclaimed concurrently (token no longer
        // matches), or another run won the destination profile. If we just
        // propagated that error, the home would hold `newProfile`'s (possibly
        // freshly refreshed) credential while the cache no longer binds it under
        // a usable lease, and `lease end` would later see an identity mismatch
        // (home=newProfile vs. lease=oldProfile) and refuse to write it back —
        // stranding the new account's credential. So on a moveLease failure we
        // write `newProfile`'s credential straight back here, release the stale
        // `oldProfile` reservation, and remove the now-disposable home, then
        // surface the error. The lease is gone, but no credential is lost
        // (invariant 1) and no reservation/home is leaked.
        let sealedAt = Date()
        do {
            try self.moveLease(
                from: oldProfile,
                to: newProfile,
                reservation: LeaseReservation(
                    token: reservation.token,
                    home: reservation.home,
                    expiresAt: sealedAt.addingTimeInterval(options.ttl),
                    createdAt: reservation.createdAt))
        } catch {
            fputs("[lease swap] could not rebind the lease to '\(newProfile)': \(error). "
                + "Writing the new account's credential back directly so it is not stranded in the leased home.\n", stderr)
            // Write `newProfile`'s credential straight back so it is not stranded
            // (invariant 1: never lose a refreshed credential).
            let directWriteback = Result {
                try self.importRefreshedAuth(dirURL: home, profile: newProfile, vault: self.vault)
            }
            // The cache still binds this token to `oldProfile` while the home now
            // holds `newProfile`'s credential — an identity mismatch that `lease
            // end`/`gc` would treat as recoverable and preserve INDEFINITELY,
            // permanently stranding the `oldProfile` reservation slot and leaking
            // the home. Once the credential is safely back in `newProfile`'s vault,
            // the home is disposable: release the stale reservation (compare-and-
            // delete on our token, so a concurrent writer's lease is untouched) and
            // remove the home. If the direct writeback itself failed, the home is
            // the only copy of `newProfile`'s credential — leave everything intact
            // so a later retry can recover it, exactly like the other writeback-
            // failure paths.
            if case .success = directWriteback {
                try? self.removeLease(profileID: oldProfile, expectedToken: reservation.token)
                if self.isLeaseHome(reservation.home, token: reservation.token) {
                    try? self.fileManager.removeItem(at: home)
                }
            }
            throw error
        }

        if options.json {
            let report = LeaseSwapReport(profile: newProfile, home: reservation.home)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print(newProfile)
        }
    }

    private struct LeaseEndOptions {
        var token: String?
        var profile: String?
        var nonInteractive = false
        var timeout: TimeInterval = 30
    }

    private static func parseLeaseEndOptions(_ args: [String]) throws -> LeaseEndOptions {
        var options = LeaseEndOptions()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--profile":
                guard i + 1 < args.count else {
                    throw CLIError.message("--profile requires a profile ID")
                }
                i += 1
                options.profile = args[i]
            case "--timeout":
                guard i + 1 < args.count,
                      let value = Double(args[i + 1]),
                      value.isFinite && value > 0 && value <= 3600 else {
                    throw CLIError.message("--timeout requires a positive number of seconds (max 3600)")
                }
                i += 1
                options.timeout = value
            case "--non-interactive":
                options.nonInteractive = true
            default:
                if args[i].hasPrefix("-") {
                    throw CLIError.message("Unknown argument: \(args[i]). Usage: \(self.program) lease end <token> [--profile <id>] [--timeout <seconds>] [--non-interactive]")
                }
                guard options.token == nil else {
                    throw CLIError.message("Unexpected extra argument: \(args[i])")
                }
                options.token = args[i]
            }
            i += 1
        }
        return options
    }

    /// Writes the refreshed credential back to its profile and tears the lease
    /// down. Idempotent and trap-safe: a shell `trap ... EXIT INT TERM` may call
    /// this more than once; no active lease is a clean no-op.
    ///
    /// Credential safety: the home holds the ONLY copy of the refreshed
    /// credential. If write-back FAILS, we do NOT delete the home or release the
    /// reservation — that would silently lose the refreshed token. Instead we
    /// warn and preserve everything for a retry; `gc` reclaims it later once the
    /// TTL lapses. Only a SUCCESSFUL (or no-op) write-back proceeds to release +
    /// remove. Release is a compare-and-delete on the token, so a fresh lease a
    /// concurrent `begin` placed on the same profile is never dropped.
    private static func commandLeaseEnd(_ args: [String]) throws {
        let options = try self.parseLeaseEndOptions(args)
        guard let token = options.token else {
            throw CLIError.message("Usage: \(self.program) lease end <token> [--profile <id>] [--timeout <seconds>] [--non-interactive]")
        }

        // No active lease = already ended or never created. Idempotent no-op so
        // a trap can fire this any number of times without error.
        guard let (foundProfile, reservation) = self.findLease(token: token) else { return }

        // `--profile` must match the lease's bound profile if given. A mismatch
        // (e.g. stale value from before a swap rebind) would write the home's
        // credential back to the WRONG account — fail fast before any writeback.
        if let override = options.profile, override != foundProfile {
            throw CLIError.message(
                "lease end --profile \(override) does not match the lease's bound profile \(foundProfile)")
        }
        let profile = foundProfile
        let home = URL(fileURLWithPath: reservation.home)

        // Disarm on the way out so an end that finishes near the timeout boundary
        // is never killed after it has already released the lease.
        let disarmWatchdog = self.armWatchdog(
            seconds: options.timeout,
            diagnostic: "lease end timed out after \(Int(options.timeout))s")
        defer { disarmWatchdog() }

        // Headless-safe writeback. On a RECOVERABLE failure (the home holds a
        // real credential the write could not land — identity mismatch exit 5, or
        // a vault save error) preserve the home + reservation and exit NON-ZERO so
        // automation can distinguish "ended and cleaned up" (exit 0) from
        // "credential recovery still pending"; gc will retry. A NON-recoverable
        // failure (no home auth, no such profile, invalid blob — exit 1) has
        // nothing to write back, so fall through to a normal clean release. The
        // idempotent "no active lease" case above already returns 0; a trap that
        // wants best-effort teardown can still append `|| true`.
        do {
            try self.importRefreshedAuth(dirURL: home, profile: profile, vault: self.vault)
        } catch {
            if self.isRecoverableWritebackError(error) {
                fputs("[lease end] write-back FAILED for '\(profile)': \(error). "
                    + "Preserving the leased home for recovery; not released (gc will reclaim it after the TTL).\n", stderr)
                throw error
            }
            fputs("[lease end] nothing to write back for '\(profile)' (\(error)); releasing the lease.\n", stderr)
            // fall through to release + remove below
        }

        // Write-back succeeded (or was a no-op): release + remove. Compare-and-
        // delete on the token; only remove the home if it is the expected path.
        try? self.removeLease(profileID: foundProfile, expectedToken: token)
        if self.isLeaseHome(reservation.home, token: token) {
            try? self.fileManager.removeItem(at: home)
        }
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

    private static func environment(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    /// Only binaries with the data-protection Keychain entitlement may use the
    /// data-protection Keychain vault. Every other binary uses the dev file vault.
    private enum EffectiveAuthBackend {
        case file(URL)
        case dataProtectionKeychain
    }

    /// The auth backend this process uses. Tests pin it with
    /// `CODEX_PROFILE_TEST_AUTH_STORE_DIR`; the menu app pins it with
    /// `CODEX_PROFILE_FILE_AUTH_STORE_DIR` so a delegated helper can use the
    /// same file vault as its caller. No environment variable can bypass the
    /// entitlement check for data-protection Keychain storage.
    private static let effectiveBackend: EffectiveAuthBackend = {
        let env = ProcessInfo.processInfo.environment
        if let path = env["CODEX_PROFILE_TEST_AUTH_STORE_DIR"], !path.isEmpty {
            return .file(URL(fileURLWithPath: path).standardizedFileURL)
        }
        if let path = env["CODEX_PROFILE_FILE_AUTH_STORE_DIR"], !path.isEmpty {
            return .file(URL(fileURLWithPath: path).standardizedFileURL)
        }
        return ProcessSigningIdentity.hasDataProtectionKeychainAccess
            ? .dataProtectionKeychain
            : .file(CodexProfileCLI.paths.devAuthStoreURL)
    }()

    private static var didNoteFileVault = false

    private static func makeVault() -> AuthVault {
        switch self.effectiveBackend {
        case let .file(root):
            if !self.didNoteFileVault,
               (ProcessInfo.processInfo.environment["CODEX_PROFILE_TEST_AUTH_STORE_DIR"] ?? "").isEmpty {
                self.didNoteFileVault = true
                fputs("""
                notice: no data-protection Keychain entitlement - using file auth vault at \(root.path).\n
                """, stderr)
            }
            return PrimaryAuthVaultSelector.makeVault(
                hasDataProtectionKeychainAccess: false,
                fileVaultRoot: root)
        case .dataProtectionKeychain:
            return PrimaryAuthVaultSelector.makeVault(
                hasDataProtectionKeychainAccess: true,
                fileVaultRoot: Self.paths.devAuthStoreURL)
        }
    }

    private static func vaultLocation(profile: String) -> String {
        switch self.effectiveBackend {
        case let .file(root):
            return root.appendingPathComponent("\(profile).json").standardizedFileURL.path
        case .dataProtectionKeychain:
            return "data-protection-keychain://v2/\(profile)"
        }
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
        self.vault.diagnostics().activeBackend.displayName
    }

    private static func note(_ text: String) {
        print(text)
    }

    /// Arms a detached watchdog that force-exits the process after `seconds`
    /// unless the returned disarm closure was called first. Runs on its own
    /// thread so it fires even if the main path is blocked in a syscall,
    /// guaranteeing callers in non-interactive shells are never stranded. The
    /// thread is daemon-like: if the command finishes first the process exits
    /// normally and the sleeping thread is torn down with it. `exec` disarms
    /// after profile selection so the watchdog never kills the wrapped child.
    @discardableResult
    private static func armWatchdog(seconds: TimeInterval, diagnostic: String) -> () -> Void {
        let state = WatchdogState()
        let thread = Thread {
            Thread.sleep(forTimeInterval: seconds)
            guard !state.disarmed else { return }
            fputs("\(diagnostic)\n", stderr)
            exit(ExitCode.watchdogTimeout)
        }
        thread.stackSize = 512 * 1024
        thread.start()
        return { state.disarm() }
    }

    private final class WatchdogState: @unchecked Sendable {
        private let lock = NSLock()
        private var isDisarmed = false
        var disarmed: Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.isDisarmed
        }

        func disarm() {
            self.lock.lock()
            self.isDisarmed = true
            self.lock.unlock()
        }
    }

    /// Maps a thrown error to the keychain-interaction exit path when the
    /// failure is the Keychain refusing to prompt. Returns true if it handled
    /// (and exited); callers rethrow otherwise.
    private static func isKeychainInteractionRequired(_ error: Error) -> Bool {
        (error as? KeychainAuthVaultError)?.isInteractionRequired ?? false
    }

    enum BlobReadOutcome {
        case data(Data?)
        case interactionRequired
    }

    /// Reads a profile's auth blob with an optional hard upper bound. In
    /// non-interactive mode the synchronous read runs on a background thread so
    /// a blocked storage operation cannot hold automation indefinitely.
    private static func loadAuthBlobBounded(
        _ vault: AuthVault,
        profileID: String,
        bound: TimeInterval?
    ) throws -> BlobReadOutcome {
        guard let bound else {
            return .data(try vault.loadAuthBlob(profileID: profileID))
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = ReadResultBox()
        let thread = Thread {
            do {
                box.set(.data(try vault.loadAuthBlob(profileID: profileID)))
            } catch {
                box.setError(error)
            }
            semaphore.signal()
        }
        thread.start()

        if semaphore.wait(timeout: .now() + bound) == .timedOut {
            return .interactionRequired
        }
        if let error = box.error { throw error }
        return box.outcome ?? .data(nil)
    }

    private final class ReadResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var outcome: BlobReadOutcome?
        private(set) var error: Error?
        func set(_ value: BlobReadOutcome) { self.lock.lock(); self.outcome = value; self.lock.unlock() }
        func setError(_ value: Error) { self.lock.lock(); self.error = value; self.lock.unlock() }
    }

    private static func exitKeychainInteractionRequired() -> Never {
        fputs("keychain interaction required; run codex-profile from a terminal once to grant access\n", stderr)
        exit(ExitCode.keychainInteractionRequired)
    }
}

private extension JSONDecoder {
    static func iso8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
