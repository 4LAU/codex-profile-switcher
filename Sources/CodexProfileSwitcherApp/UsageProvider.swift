import Foundation
import CodexProfileCore
import CryptoKit

// MARK: - UsageProvider

@MainActor
final class UsageProvider {
    private let store: ProfileStore
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UUID?
    private var lastRefreshAll: Date = .distantPast
    private(set) var isRefreshing = false
    /// Leases currently held by this refresh cycle, keyed by profile ID, so
    /// `cancelRefreshes()` can release them immediately instead of waiting on
    /// an in-flight task's own `defer` — cooperative cancellation means that
    /// defer only runs once the task next checks `Task.isCancelled`, which can
    /// lag a cancellation by a couple of seconds while a fetch is in flight.
    private var activeLeases: [String: String] = [:]
    /// The in-flight lease release started by `cancelRefreshes()`. Releasing is
    /// `async` (the flock must stay off the main thread), and `clearSavedAuth`
    /// cancels and then immediately requests a fresh refresh — so without this
    /// handle the new refresh can reach `claimLease` before the old lease row
    /// is gone and lose its own claim for the lease's full lifetime. Awaited
    /// before any claim, which makes the ordering deterministic.
    private var pendingLeaseRelease: Task<Void, Never>?
    var onRefreshComplete: (() -> Void)?

    init(store: ProfileStore) {
        self.store = store
    }

    func cancelRefreshes() {
        let cancelledActiveRefresh = self.refreshGeneration != nil
        self.refreshTask?.cancel()
        self.refreshTask = nil
        self.refreshGeneration = nil
        self.isRefreshing = false
        // removeLease is `async` (it holds the flock, which must stay off the
        // main thread) and this method's callers are synchronous, so the
        // releases start here and are awaited at the next claim rather than
        // blocking this main-actor call. Chained onto any previous release so
        // two cancels in a row cannot reorder.
        let leasesToRelease = self.activeLeases
        self.activeLeases.removeAll()
        if !leasesToRelease.isEmpty {
            let previous = self.pendingLeaseRelease
            self.pendingLeaseRelease = Task {
                await previous?.value
                for (profileID, token) in leasesToRelease {
                    await Self.removeLease(profileIDs: [profileID], expectedToken: token)
                }
            }
        }
        if cancelledActiveRefresh {
            self.store.flushCacheIfDirty()
        }
    }

    func refreshAll(force: Bool = false) {
        guard !self.isRefreshing else { return }
        guard force || Date().timeIntervalSince(self.lastRefreshAll) > 60 else { return }

        // The nightly renewal LaunchAgent writes rejections to the shared cache
        // file from a separate process; re-read them at the start of every
        // cycle so this run's statuses reflect the current on-disk state.
        self.store.reloadRenewalStatesFromDisk()

        if !force,
           self.store.statuses.values.allSatisfy({
               switch $0 {
               case .notSetUp: return true
               default: return false
               }
           }) {
            return
        }

        self.lastRefreshAll = Date()
        self.isRefreshing = true
        let generation = UUID()
        self.refreshGeneration = generation

        let profiles = self.store.config.profiles
        let liveId = self.store.liveProfileId ?? ""
        let contexts = profiles.map { p in
            RefreshContext(id: p.id, cached: self.store.cache.snapshots[p.id], isLive: p.id == liveId)
        }
        let source = self.store.usageAuthSource()

        self.refreshTask = Task { @MainActor in
            let groups = await Self.groupContexts(contexts, source: source)
            await withTaskGroup(of: Void.self) { group in
                var pending = groups[...]
                let initialBatch = min(3, pending.count)
                for _ in 0 ..< initialBatch {
                    let fetchGroup = pending.removeFirst()
                    group.addTask { @MainActor in
                        await self.refreshGroup(fetchGroup, generation: generation, source: source)
                    }
                }
                for await _ in group {
                    if let fetchGroup = pending.popFirst() {
                        group.addTask { @MainActor in
                            await self.refreshGroup(fetchGroup, generation: generation, source: source)
                        }
                    }
                }
            }
            if self.refreshGeneration == generation {
                self.isRefreshing = false
                self.refreshTask = nil
                self.refreshGeneration = nil
                self.store.flushCacheIfDirty()
                self.onRefreshComplete?()
            }
        }
    }

    private struct RefreshContext {
        let id: String
        let cached: UsageSnapshot?
        let isLive: Bool
        /// This profile's own credential fingerprint (SHA-256(refresh token),
        /// first 12 hex chars — matches the CLI's `renewalCredentialFingerprint`),
        /// computed from its individually-loaded auth blob before batching by
        /// identity. Used to detect that a persisted rejection's credential has
        /// been replaced. Nil when the auth blob could not be loaded or parsed.
        var credentialFingerprint: String? = nil
    }

    private struct RefreshGroup {
        var contexts: [RefreshContext]
        let authData: Data?
        let loadError: (any Error)?
    }

    private nonisolated static func groupContexts(
        _ contexts: [RefreshContext], source: ProfileStore.UsageAuthSource
    ) async -> [RefreshGroup] {
        var groups: [String: RefreshGroup] = [:]
        for var context in contexts {
            var loadError: (any Error)?
            var authData: Data?
            do {
                authData = try await Self.loadAuthData(
                    source: source, profileID: context.id, isLive: context.isLive)
            } catch {
                loadError = error
            }
            context.credentialFingerprint = authData.flatMap(Self.credentialFingerprint(from:))
            // Group by credential fingerprint, not identity: this batches
            // per-profile usage/health refreshes, and two profiles sharing an
            // account identity can still hold different credentials. Batching
            // by identity would fetch one profile's usage and apply it to a
            // sibling profile with a different refresh token.
            let key = context.credentialFingerprint ?? "profile:\(context.id)"
            if var group = groups[key] {
                group.contexts.append(context)
                groups[key] = group
            } else {
                groups[key] = RefreshGroup(contexts: [context], authData: authData, loadError: loadError)
            }
        }
        return Array(groups.values)
    }

    /// Mirrors the CLI's `renewalCredentialFingerprint`: SHA-256 of the refresh
    /// token, first 12 hex characters. Used to detect when a profile's stored
    /// credential has moved past the one a persisted rejection condemned.
    private nonisolated static func credentialFingerprint(from authData: Data) -> String? {
        guard let credentials = try? AuthBlob.load(from: authData), !credentials.refreshToken.isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: Data(credentials.refreshToken.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return String(digest.prefix(12))
    }

    private func refreshGroup(
        _ fetchGroup: RefreshGroup, generation: UUID, source: ProfileStore.UsageAuthSource
    ) async {
        guard !self.store.isAuthMutationInProgress() else { return }
        var diagnostics = Dictionary(uniqueKeysWithValues: fetchGroup.contexts.map {
            ($0.id, ProfileRefreshDiagnostics(lastAttemptAt: Date()))
        })

        func finalize(
            _ context: RefreshContext, _ status: ProfileStatus, decision: String
        ) async {
            // Bail if the refresh was cancelled (e.g. by cancelRefreshes() during
            // a profile switch). Prevents in-flight stale writes from landing.
            guard !Task.isCancelled, self.refreshGeneration == generation else { return }

            self.store.clearRenewalStateIfCredentialMoved(
                for: context.id, currentCredentialFingerprint: context.credentialFingerprint)

            // Re-derive liveness at finalize time. The snapshot was fetched under
            // whichever credentials were live at refresh START; if the live
            // profile changed mid-flight, this snapshot was read against the wrong
            // auth.json and must not be written under `id`. The post-switch forced
            // refreshAll will supply correct data, so we drop the result here.
            let currentlyLive = context.id == (self.store.liveProfileId ?? "")
            if context.isLive != currentlyLive { return }

            diagnostics[context.id]?.lastDecision = decision
            // Re-check whether auth was torn down while we fetched. Live profiles
            // use a cheap main-safe file stat; non-live profiles re-query the
            // vault, but off the main actor so a Keychain consent prompt cannot
            // block the menu bar.
            let stillAvailable = currentlyLive
                ? self.store.liveAuthExists()
                : await Self.loadAuthAvailability(source: source, profileID: context.id)
            guard !Task.isCancelled, self.refreshGeneration == generation else { return }
            if !stillAvailable {
                let overrideDecision = context.cached != nil ? "relogin-needed" : "not-set-up"
                diagnostics[context.id]?.lastDecision = overrideDecision
                self.store.updateRefreshDiagnostics(context.id, diagnostics[context.id]!)
                self.store.updateStatus(context.id, context.cached.map { .reloginNeeded($0) } ?? .notSetUp)
                return
            }
            self.store.updateRefreshDiagnostics(context.id, diagnostics[context.id]!)
            self.store.updateStatus(context.id, status)
        }

        guard let authData = fetchGroup.authData else {
            for context in fetchGroup.contexts {
                if let error = fetchGroup.loadError {
                    // Loading the auth blob threw. `.notFound` means genuinely no
                    // credential; any other error (e.g. a Keychain read failure)
                    // must not be reported as "not set up" — fall back to the
                    // last-known snapshot and surface the error, matching the
                    // pre-batching behavior this replaced.
                    diagnostics[context.id]?.lastError = error.localizedDescription
                    if let authError = error as? AuthError, case .notFound = authError {
                        await finalize(context, .notSetUp, decision: "not-set-up")
                    } else {
                        await finalize(context, .stale(context.cached), decision: "stale")
                        AppLogger.warning("Usage refresh failed",
                                          metadata: ["profile": context.id, "error": error.localizedDescription])
                    }
                } else {
                    await finalize(context, .notSetUp, decision: "not-set-up")
                }
            }
            return
        }

        let reservation = LeaseReservation(
            token: UUID().uuidString,
            home: "",
            expiresAt: Date().addingTimeInterval(60),
            createdAt: Date())
        await self.pendingLeaseRelease?.value
        guard await Self.claimLease(
            profileIDs: fetchGroup.contexts.map(\.id), reservation: reservation) else {
            for context in fetchGroup.contexts {
                await finalize(context, .stale(context.cached), decision: "reserved")
            }
            return
        }
        for context in fetchGroup.contexts {
            self.activeLeases[context.id] = reservation.token
        }
        // `removeLease` is `async` (F24: it holds `flock` and must stay off
        // the main thread), and `defer` cannot contain `await`, so the lease
        // release below is called explicitly on every exit path from this
        // point instead of via `defer`. There are exactly two: the
        // `CancellationError` early return, and falling off the end of the
        // `do`/`catch` below.

        do {
            let snapshot = try await CLIUsageFetcher.fetch(
                profileId: fetchGroup.contexts[0].id, authData: authData, codexConfigURL: self.store.codexConfigURL(),
                clientVersion: AppInfo.version)
            for context in fetchGroup.contexts {
                diagnostics[context.id]?.lastError = nil
                await finalize(context, .available(snapshot), decision: "available")
                AppLogger.info("Usage refresh succeeded", metadata: ["profile": context.id])
            }
        } catch is CancellationError {
            await self.releaseLease(fetchGroup.contexts.map(\.id), expectedToken: reservation.token)
            return
        } catch let error as CodexRPCError where error.isAuthRequired {
            for context in fetchGroup.contexts {
                diagnostics[context.id]?.lastError = error.localizedDescription
                await finalize(context, .reloginNeeded(context.cached), decision: "relogin-needed")
                AppLogger.warning("Usage refresh requires re-login",
                                  metadata: ["profile": context.id, "error": error.localizedDescription])
            }
        } catch let error as AuthError {
            for context in fetchGroup.contexts {
                diagnostics[context.id]?.lastError = error.localizedDescription
                if case .notFound = error {
                    await finalize(context, .notSetUp, decision: "not-set-up")
                } else {
                    await finalize(context, .stale(context.cached), decision: "stale")
                    AppLogger.warning("Usage refresh failed",
                                      metadata: ["profile": context.id, "error": error.localizedDescription])
                }
            }
        } catch {
            for context in fetchGroup.contexts {
                diagnostics[context.id]?.lastError = error.localizedDescription
                await finalize(context, .stale(context.cached), decision: "stale")
                AppLogger.warning("Usage refresh failed",
                                  metadata: ["profile": context.id, "error": error.localizedDescription])
            }
        }
        await self.releaseLease(fetchGroup.contexts.map(\.id), expectedToken: reservation.token)
    }

    /// Releases a lease claimed by `refreshGroup` and clears it from
    /// `activeLeases`. Called explicitly at every exit point of
    /// `refreshGroup` after the lease is claimed, since `removeLease` is
    /// `async` and `defer` bodies cannot contain `await`.
    private func releaseLease(_ profileIDs: [String], expectedToken: String) async {
        await Self.removeLease(profileIDs: profileIDs, expectedToken: expectedToken)
        for id in profileIDs where self.activeLeases[id] == expectedToken {
            self.activeLeases.removeValue(forKey: id)
        }
    }

    /// Thrown inside the lock closures below to short-circuit a write when
    /// `loadCache` reports `.decodeFailed` — the on-disk cache is
    /// unknown-but-real and must not be clobbered with an empty/partial one.
    private struct CacheDecodeFailed: Error {}

    private nonisolated static func claimLease(
        profileIDs: [String], reservation: LeaseReservation
    ) async -> Bool {
        let paths = AppPaths()
        do {
            try CacheLock.withLock(at: paths.cacheLockURL) {
                var cache: UsageCache
                switch Self.loadCache(paths: paths) {
                case .missing:
                    cache = UsageCache(snapshots: [:])
                case .loaded(let loaded):
                    cache = loaded
                case .decodeFailed:
                    AppLogger.warning(
                        "Usage cache failed to decode; refusing to claim lease over unknown on-disk state",
                        metadata: ["path": paths.cacheURL.path])
                    throw CacheDecodeFailed()
                }
                for profileID in profileIDs {
                    if let existing = cache.leases[profileID], existing.token != reservation.token {
                        guard existing.isActive() || !existing.home.isEmpty else {
                            cache.leases.removeValue(forKey: profileID)
                            continue
                        }
                        throw LeaseClaimLost()
                    }
                }
                for profileID in profileIDs {
                    cache.leases[profileID] = reservation
                }
                try Self.saveCache(cache, paths: paths)
            }
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func removeLease(
        profileIDs: [String], expectedToken: String
    ) async {
        let paths = AppPaths()
        try? CacheLock.withLock(at: paths.cacheLockURL) {
            var cache: UsageCache
            switch Self.loadCache(paths: paths) {
            case .missing:
                cache = UsageCache(snapshots: [:])
            case .loaded(let loaded):
                cache = loaded
            case .decodeFailed:
                AppLogger.warning(
                    "Usage cache failed to decode; refusing to release lease over unknown on-disk state",
                    metadata: ["path": paths.cacheURL.path])
                return
            }
            for profileID in profileIDs where cache.leases[profileID]?.token == expectedToken {
                cache.leases.removeValue(forKey: profileID)
            }
            try Self.saveCache(cache, paths: paths)
        }
    }

    /// Outcome of attempting to load the on-disk cache. Distinguishes "no file
    /// yet" (an empty cache is the correct value, safe to write back) from
    /// "a file exists but didn't decode" (its content is unknown-but-real —
    /// missing, unreadable, corrupt, or containing a sub-record shape this
    /// build can't parse — and callers must not overwrite it). See F21.
    private enum CacheLoadResult {
        case missing
        case decodeFailed
        case loaded(UsageCache)
    }

    private nonisolated static func loadCache(paths: AppPaths) -> CacheLoadResult {
        guard FileManager.default.fileExists(atPath: paths.cacheURL.path) else {
            return .missing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: paths.cacheURL),
              let cache = try? decoder.decode(UsageCache.self, from: data) else {
            return .decodeFailed
        }
        return .loaded(cache)
    }

    private nonisolated static func saveCache(_ cache: UsageCache, paths: AppPaths) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFileWriter.write(try encoder.encode(cache), to: paths.cacheURL)
    }

    private struct LeaseClaimLost: Error {}

    /// Loads the auth blob off the main actor. `nonisolated` so that awaiting it
    /// from the main actor runs the body on the global concurrent executor,
    /// keeping the potentially-blocking file/Keychain syscall off the main thread.
    private nonisolated static func loadAuthData(
        source: ProfileStore.UsageAuthSource, profileID: String, isLive: Bool
    ) async throws -> Data? {
        if isLive {
            guard FileManager.default.fileExists(atPath: source.liveAuthURL.path) else { return nil }
            return try Data(contentsOf: source.liveAuthURL)
        }
        return try source.vault.loadAuthBlob(profileID: profileID)
    }

    /// Checks a non-live profile's auth-blob availability off the main actor,
    /// mirroring the threading of `loadAuthData` so a Keychain consent prompt
    /// cannot block the main thread.
    private nonisolated static func loadAuthAvailability(
        source: ProfileStore.UsageAuthSource, profileID: String
    ) async -> Bool {
        ((try? source.vault.authBlobAvailability(profileID: profileID)) ?? .missing) == .present
    }
}
