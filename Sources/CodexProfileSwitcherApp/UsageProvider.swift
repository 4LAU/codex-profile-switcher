import Foundation
import CodexProfileCore

// MARK: - UsageProvider

@MainActor
final class UsageProvider {
    private let store: ProfileStore
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UUID?
    private var lastRefreshAll: Date = .distantPast
    private(set) var isRefreshing = false
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
        if cancelledActiveRefresh {
            self.store.flushCacheIfDirty()
        }
    }

    func refreshAll(force: Bool = false) {
        guard !self.isRefreshing else { return }
        guard force || Date().timeIntervalSince(self.lastRefreshAll) > 60 else { return }

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
    }

    private struct RefreshGroup {
        var contexts: [RefreshContext]
        let authData: Data?
    }

    private nonisolated static func groupContexts(
        _ contexts: [RefreshContext], source: ProfileStore.UsageAuthSource
    ) async -> [RefreshGroup] {
        var groups: [String: RefreshGroup] = [:]
        for context in contexts {
            let authData = try? await Self.loadAuthData(
                source: source, profileID: context.id, isLive: context.isLive)
            let key = authData.flatMap { AuthBlob.identityFingerprint(from: $0) } ?? "profile:\(context.id)"
            if var group = groups[key] {
                group.contexts.append(context)
                groups[key] = group
            } else {
                groups[key] = RefreshGroup(contexts: [context], authData: authData ?? nil)
            }
        }
        return Array(groups.values)
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
                await finalize(context, .notSetUp, decision: "not-set-up")
            }
            return
        }

        let reservation = LeaseReservation(
            token: UUID().uuidString,
            home: "",
            expiresAt: Date().addingTimeInterval(5 * 60),
            createdAt: Date())
        guard Self.claimLease(
            profileIDs: fetchGroup.contexts.map(\.id), reservation: reservation) else {
            for context in fetchGroup.contexts {
                await finalize(context, .stale(context.cached), decision: "reserved")
            }
            return
        }
        defer {
            Self.removeLease(
                profileIDs: fetchGroup.contexts.map(\.id), expectedToken: reservation.token)
        }

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
    }

    private nonisolated static func claimLease(
        profileIDs: [String], reservation: LeaseReservation
    ) -> Bool {
        let paths = AppPaths()
        do {
            try CacheLock.withLock(at: paths.cacheLockURL) {
                var cache = Self.loadCache(paths: paths)
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
    ) {
        let paths = AppPaths()
        try? CacheLock.withLock(at: paths.cacheLockURL) {
            var cache = Self.loadCache(paths: paths)
            for profileID in profileIDs where cache.leases[profileID]?.token == expectedToken {
                cache.leases.removeValue(forKey: profileID)
            }
            try Self.saveCache(cache, paths: paths)
        }
    }

    private nonisolated static func loadCache(paths: AppPaths) -> UsageCache {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: paths.cacheURL))
            .flatMap { try? decoder.decode(UsageCache.self, from: $0) }
            ?? UsageCache(snapshots: [:])
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
