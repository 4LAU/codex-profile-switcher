import Foundation
import CodexProfileCore

// MARK: - UsageProvider

@MainActor
final class UsageProvider {
    private let store: ProfileStore
    private var refreshTask: Task<Void, Never>?
    private var lastRefreshAll: Date = .distantPast
    private(set) var isRefreshing = false
    var onRefreshComplete: (() -> Void)?

    init(store: ProfileStore) {
        self.store = store
    }

    func cancelRefreshes() {
        self.refreshTask?.cancel()
        self.refreshTask = nil
        self.isRefreshing = false
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

        let profiles = self.store.config.profiles
        let liveId = self.store.liveProfileId ?? ""
        let contexts: [(String, UsageSnapshot?)] = profiles.map { p in
            (p.id, self.store.cache.snapshots[p.id])
        }

        self.refreshTask = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                var pending = contexts[...]
                let initialBatch = min(3, pending.count)
                for _ in 0 ..< initialBatch {
                    let (id, cached) = pending.removeFirst()
                    group.addTask { @MainActor in
                        await self.refreshProfile(id, activeProfileId: liveId, cached: cached)
                    }
                }
                for await _ in group {
                    if let (id, cached) = pending.popFirst() {
                        group.addTask { @MainActor in
                            await self.refreshProfile(id, activeProfileId: liveId, cached: cached)
                        }
                    }
                }
            }
            self.isRefreshing = false
            self.refreshTask = nil
            self.store.flushCacheIfDirty()
            self.onRefreshComplete?()
        }
    }

    private func refreshProfile(
        _ id: String, activeProfileId: String, cached: UsageSnapshot?
    ) async {
        guard !self.store.isAuthMutationInProgress() else { return }
        var diagnostics = ProfileRefreshDiagnostics(lastAttemptAt: Date())

        // Snapshot the plain values the blocking reads need, on the main actor.
        // `UsageAuthSource` carries only immutable value types (the vault is an
        // immutable struct conformer), so the read can run off the main actor
        // without touching ProfileStore's mutable state.
        let source = self.store.usageAuthSource()
        let isLive = id == activeProfileId

        func finalize(_ status: ProfileStatus, decision: String) async {
            // Bail if the refresh was cancelled (e.g. by cancelRefreshes() during
            // a profile switch). Prevents in-flight stale writes from landing.
            guard !Task.isCancelled else { return }

            // Re-derive liveness at finalize time. The snapshot was fetched under
            // whichever credentials were live at refresh START; if the live
            // profile changed mid-flight, this snapshot was read against the wrong
            // auth.json and must not be written under `id`. The post-switch forced
            // refreshAll will supply correct data, so we drop the result here.
            let currentlyLive = id == (self.store.liveProfileId ?? "")
            if isLive != currentlyLive { return }

            diagnostics.lastDecision = decision
            // Re-check whether auth was torn down while we fetched. Live profiles
            // use a cheap main-safe file stat; non-live profiles re-query the
            // vault, but off the main actor so a Keychain consent prompt cannot
            // block the menu bar.
            let stillAvailable = currentlyLive
                ? self.store.liveAuthExists()
                : await Self.loadAuthAvailability(source: source, profileID: id)
            if !stillAvailable {
                let overrideDecision = cached != nil ? "relogin-needed" : "not-set-up"
                diagnostics.lastDecision = overrideDecision
                self.store.updateRefreshDiagnostics(id, diagnostics)
                self.store.updateStatus(id, cached.map { .reloginNeeded($0) } ?? .notSetUp)
                return
            }
            self.store.updateRefreshDiagnostics(id, diagnostics)
            self.store.updateStatus(id, status)
        }

        do {
            // Perform the potentially-blocking auth read off the main actor. A
            // single read replaces the prior availability-check + load (two
            // Keychain hits) while preserving the outcome: no auth -> notSetUp.
            guard let authData = try await Self.loadAuthData(source: source, profileID: id, isLive: isLive) else {
                await finalize(.notSetUp, decision: "not-set-up")
                return
            }
            let snapshot = try await CLIUsageFetcher.fetch(
                profileId: id, authData: authData, codexConfigURL: self.store.codexConfigURL(),
                clientVersion: AppInfo.version)
            diagnostics.lastError = nil
            await finalize(.available(snapshot), decision: "available")
            AppLogger.info("Usage refresh succeeded", metadata: ["profile": id])
        } catch is CancellationError {
            return
        } catch let error as CodexRPCError where error.isAuthRequired {
            diagnostics.lastError = error.localizedDescription
            await finalize(.reloginNeeded(cached), decision: "relogin-needed")
            AppLogger.warning("Usage refresh requires re-login",
                              metadata: ["profile": id, "error": error.localizedDescription])
        } catch let error as AuthError {
            if case .notFound = error {
                diagnostics.lastError = error.localizedDescription
                await finalize(.notSetUp, decision: "not-set-up")
            } else {
                diagnostics.lastError = error.localizedDescription
                await finalize(.stale(cached), decision: "stale")
                AppLogger.warning("Usage refresh failed",
                                  metadata: ["profile": id, "error": error.localizedDescription])
            }
        } catch {
            diagnostics.lastError = error.localizedDescription
            await finalize(.stale(cached), decision: "stale")
            AppLogger.warning("Usage refresh failed", metadata: ["profile": id, "error": error.localizedDescription])
        }
    }

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
