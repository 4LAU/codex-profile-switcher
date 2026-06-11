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
    private static let keychainService = Self.environment("CODEX_PROFILE_KEYCHAIN_SERVICE")
        ?? KeychainAuthVault.defaultService
    private static let vault = Self.makeVault()
    private static let keychainAccessRepairVersion = 4
    private static let version = "0.4.1"

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
            case "best-auth": try self.commandBestAuth(args)
            case "exec": try self.commandExec(args)
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
          \(self.program) status [profile] [--json]
          \(self.program) list [--json]
          \(self.program) path <profile>
          \(self.program) doctor
          \(self.program) keychain-repair
          \(self.program) best-auth --dir <path> [--exclude <id1,id2,...>] [--json] [--non-interactive] [--timeout <seconds>]
          \(self.program) exec [--max-attempts <n>] [--exclude <id1,id2,...>] [--timeout <seconds>] -- <command> [args...]
          \(self.program) import-auth --dir <path> --profile <id>

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
        self.repairKeychainAccessIfNeeded()

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
        try self.commandList([])
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

    /// Repairs Keychain ACLs for stored auth items when the stored version is
    /// out of date. MUST only be called on interactive paths (i.e. inside an
    /// `if interactive` guard or from a command that always runs with a TTY).
    /// The load-bearing `if interactive` guard in `commandBestAuth` is what
    /// keeps this from being called in non-interactive mode — removing that
    /// guard would cause a modal Keychain consent prompt to hang the process
    /// with no UI to render it.
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

        // Non-interactive whenever stdin is not a TTY or the caller asked. This
        // selects the fail-closed Keychain vault so reads can never block on a
        // modal consent prompt that has no UI to render.
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
        let bestAuthVault = self.makeVault(interactionAllowed: interactive)

        let config = self.configStore.loadConfig() ?? AppConfig(profiles: [], activeProfile: "")

        // Profiles-configured check is purely file-based and runs before any
        // Keychain read, so exit 3 stays fast and prompt-free.
        if config.profiles.isEmpty {
            fputs("No profiles configured\n", stderr)
            throw CLIError.exitStatus(ExitCode.noProfilesConfigured)
        }

        if interactive {
            self.repairKeychainAccessIfNeeded()
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

        // Data reads can trigger a non-suppressible ACL prompt for legacy
        // trusted-app Keychain items, so bound them in non-interactive mode.
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
        // Preserve any overrides already on disk that aren't in our copy.
        let toWrite = cache.mergingDiskOverrides(
            fromCacheAt: self.paths.cacheURL,
            decoder: JSONDecoder.iso8601Decoder())
        try? self.saveCache(toWrite)
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
        var cache = self.loadCache()
        cache.exhaustionOverrides[profile] = ExhaustionOverride(
            blockedUntil: blockedUntil,
            reason: "rate_limit",
            source: source)
        try self.saveCache(cache)
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
        try self.importRefreshedAuth(
            dirURL: URL(fileURLWithPath: dir).resolvingSymlinksInPath().standardizedFileURL,
            profile: profile)
    }

    /// Write-back core shared by `import-auth` and `exec`: saves `dirURL`'s
    /// auth.json over the stored credential for `profile`, but only when it
    /// validates and its identity fingerprint matches the stored one.
    private static func importRefreshedAuth(dirURL: URL, profile: String) throws {
        let authURL = dirURL.appendingPathComponent("auth.json")
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

        try self.vault.saveAuthBlob(updatedData, profileID: profile)
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
        for _ in 0 ..< attempts {
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

    /// Unsigned (ad-hoc) builds never touch the real Keychain: every rebuild
    /// has a new code identity, which would trigger a macOS consent prompt per
    /// saved profile. They get a separate file-based dev vault instead (the
    /// CodexBar pattern). Signed builds (`make install-cli`, releases) use the
    /// Keychain and share the real profiles.
    private static let devVaultActive: Bool = {
        if let path = ProcessInfo.processInfo.environment["CODEX_PROFILE_TEST_AUTH_STORE_DIR"],
           !path.isEmpty {
            return false
        }
        return !ProcessSigningIdentity.isStable
    }()

    private static var didNoteDevVault = false

    private static func makeVault(interactionAllowed: Bool = true) -> AuthVault {
        if let path = self.environment("CODEX_PROFILE_TEST_AUTH_STORE_DIR"), !path.isEmpty {
            return FileAuthVault(root: URL(fileURLWithPath: path).standardizedFileURL)
        }
        if self.devVaultActive {
            if !self.didNoteDevVault {
                self.didNoteDevVault = true
                fputs("""
                notice: unsigned dev build - using file auth vault at \(self.paths.devAuthStoreURL.path) \
                (the macOS Keychain is not touched). Build a signed CLI with `make install-cli` \
                to share the real Keychain profiles.\n
                """, stderr)
            }
            return FileAuthVault(root: self.paths.devAuthStoreURL)
        }
        return LegacyKeychainAuthVault(service: self.keychainService, interactionAllowed: interactionAllowed)
    }

    private static func vaultLocation(profile: String) -> String {
        if let path = self.environment("CODEX_PROFILE_TEST_AUTH_STORE_DIR"), !path.isEmpty {
            return URL(fileURLWithPath: path)
                .appendingPathComponent("\(profile).json")
                .standardizedFileURL
                .path
        }
        if self.devVaultActive {
            return self.paths.devAuthStoreURL.appendingPathComponent("\(profile).json").path
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

    /// Reads a profile's auth blob with a hard upper bound. The Keychain data
    /// read for legacy trusted-application ACL items shows a modal consent
    /// prompt that `kSecUseAuthenticationUIFail` does NOT suppress, so in
    /// non-interactive mode we race the (synchronous, uncancellable) read on a
    /// background thread against `bound`. If the bound wins, a prompt is up with
    /// no UI to answer it: we report `.interactionRequired` and the caller maps
    /// that to a clean exit instead of hanging. In interactive mode `bound` is
    /// nil and the read proceeds normally so the user can answer the prompt.
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
