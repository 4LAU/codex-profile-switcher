import Foundation
import CodexProfileCore

// MARK: - UsageProvider

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

        self.refreshTask = Task {
            await withTaskGroup(of: Void.self) { group in
                var pending = contexts[...]
                let initialBatch = min(3, pending.count)
                for _ in 0..<initialBatch {
                    let (id, cached) = pending.removeFirst()
                    group.addTask {
                        await self.refreshProfile(id, activeProfileId: liveId, cached: cached)
                    }
                }
                for await _ in group {
                    if let (id, cached) = pending.popFirst() {
                        group.addTask {
                            await self.refreshProfile(id, activeProfileId: liveId, cached: cached)
                        }
                    }
                }
            }
            await MainActor.run {
                self.isRefreshing = false
                self.refreshTask = nil
                self.store.flushCacheIfDirty()
                self.onRefreshComplete?()
            }
        }
    }

    private func refreshProfile(
        _ id: String, activeProfileId: String, cached: UsageSnapshot?
    ) async {
        guard !self.store.isAuthMutationInProgress() else { return }
        var diagnostics = ProfileRefreshDiagnostics(lastAttemptAt: Date())

        func finalize(_ status: ProfileStatus, decision: String) async {
            diagnostics.lastDecision = decision
            await MainActor.run {
                if !self.canUseAuth(for: id, activeProfileId: activeProfileId) {
                    let overrideDecision = cached != nil ? "relogin-needed" : "not-set-up"
                    diagnostics.lastDecision = overrideDecision
                    self.store.updateRefreshDiagnostics(id, diagnostics)
                    self.store.updateStatus(id, cached.map { .reloginNeeded($0) } ?? .notSetUp)
                    return
                }
                self.store.updateRefreshDiagnostics(id, diagnostics)
                self.store.updateStatus(id, status)
            }
        }

        do {
            guard self.canUseAuth(for: id, activeProfileId: activeProfileId) else {
                await finalize(.notSetUp, decision: "not-set-up")
                return
            }
            guard let authData = try self.store.authDataForUsage(profileId: id, activeProfileId: activeProfileId) else {
                throw AuthError.notFound
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

    private func canUseAuth(for id: String, activeProfileId: String) -> Bool {
        if id == activeProfileId {
            return self.store.liveAuthExists()
        }
        return self.store.authStoreExists(for: id)
    }
}
