import Cocoa
import CodexProfileCore
import CryptoKit
import SwiftUI

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
                for (id, cached) in contexts {
                    group.addTask {
                        await self.refreshProfile(id, activeProfileId: liveId, cached: cached)
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

        let selectedMode: UsageRefreshSource = .auto
        var diagnostics = ProfileRefreshDiagnostics(selectedMode: selectedMode)

        func setDiagnostics() async {
            let snapshot = diagnostics
            await MainActor.run { self.store.updateRefreshDiagnostics(id, snapshot) }
        }

        func finalize(_ status: ProfileStatus, decision: String) async {
            diagnostics.lastDecision = decision
            let snapshot = diagnostics
            await MainActor.run {
                if !self.canUseAuth(for: id, activeProfileId: activeProfileId) {
                    self.store.updateRefreshDiagnostics(id, snapshot)
                    self.store.updateStatus(id, cached.map { .reloginNeeded($0) } ?? .notSetUp)
                    return
                }
                self.store.updateRefreshDiagnostics(id, snapshot)
                self.store.updateStatus(id, status)
            }
        }

        func makeSnapshot(from response: UsageResponse) -> UsageSnapshot {
            UsageSnapshot(
                planType: response.planType,
                creditsRemaining: response.credits?.balance,
                primaryUsedPercent: response.rateLimit?.primaryWindow?.usedPercent ?? 0,
                primaryResetAt: response.rateLimit?.primaryWindow.map {
                    Date(timeIntervalSince1970: TimeInterval($0.resetAt))
                },
                secondaryUsedPercent: response.rateLimit?.secondaryWindow?.usedPercent ?? 0,
                secondaryResetAt: response.rateLimit?.secondaryWindow.map {
                    Date(timeIntervalSince1970: TimeInterval($0.resetAt))
                },
                fetchedAt: Date())
        }

        func fetchOAuthSnapshot() async throws -> UsageSnapshot {
            guard let authData = try self.store.authDataForUsage(profileId: id, activeProfileId: activeProfileId) else {
                throw AuthError.notFound
            }
            let creds = try await AuthRefresher.refreshIfNeeded(
                profileId: id,
                activeProfileId: activeProfileId,
                authData: authData,
                currentAuthData: {
                    try self.store.currentSavedAuthData(for: id)
                },
                saveUpdatedAuthData: { [authData] data in
                    try self.store.saveRefreshedAuthToVault(data, for: id, originalData: authData)
                })

            let response = try await UsageFetcher.fetch(
                accessToken: creds.accessToken,
                accountId: creds.accountId)
            return makeSnapshot(from: response)
        }

        func attemptCLIFallback(reason: OAuthFallbackReason, sourceError: Error) async {
            diagnostics.lastFallbackReason = reason.rawValue
            diagnostics.lastError = sourceError.localizedDescription
            AppLogger.info("Usage refresh falling back to Codex CLI",
                           metadata: [
                               "profile": id,
                               "from": UsageRefreshSource.oauth.rawValue,
                               "reason": reason.rawValue,
                           ])

            diagnostics.lastAttemptedSource = .cli
            await setDiagnostics()

            do {
                guard let authData = try self.store.authDataForUsage(
                    profileId: id,
                    activeProfileId: activeProfileId) else {
                    throw AuthError.notFound
                }
                let cliSnapshot = try await CLIUsageFetcher.fetch(
                    profileId: id,
                    authData: authData,
                    codexConfigURL: self.store.codexConfigURL())

                diagnostics.lastSuccessfulSource = .cli
                diagnostics.lastError = nil
                await finalize(.available(cliSnapshot), decision: "available")
                AppLogger.info("Usage refresh succeeded",
                               metadata: [
                                   "profile": id,
                                   "mode": selectedMode.rawValue,
                                   "source": UsageRefreshSource.cli.rawValue,
                                   "reason": reason.rawValue,
                               ])
            } catch is CancellationError {
                return
            } catch let error as CodexRPCError where error.isAuthRequired {
                diagnostics.lastError = error.localizedDescription
                await finalize(.reloginNeeded(cached), decision: "relogin-needed")
                AppLogger.warning("Codex CLI fallback requires re-login",
                                  metadata: [
                                      "profile": id,
                                      "reason": reason.rawValue,
                                      "error": error.localizedDescription,
                                  ])
            } catch {
                diagnostics.lastError = error.localizedDescription
                await finalize(.stale(cached), decision: "stale")
                AppLogger.warning("Codex CLI fallback failed",
                                  metadata: [
                                      "profile": id,
                                      "reason": reason.rawValue,
                                      "error": error.localizedDescription,
                                  ])
            }
        }

        do {
            guard self.canUseAuth(for: id, activeProfileId: activeProfileId) else {
                await finalize(.notSetUp, decision: "not-set-up")
                return
            }

            diagnostics.lastAttemptedSource = .oauth
            await setDiagnostics()

            let snapshot = try await fetchOAuthSnapshot()
            diagnostics.lastSuccessfulSource = .oauth
            diagnostics.lastError = nil
            await finalize(.available(snapshot), decision: "available")
            AppLogger.info("Usage refresh succeeded",
                           metadata: [
                               "profile": id,
                               "mode": selectedMode.rawValue,
                               "source": UsageRefreshSource.oauth.rawValue,
                           ])
        } catch is CancellationError {
            return
        } catch let error as UsageFetchError where error == .unauthorized {
            AppLogger.warning("Usage refresh unauthorized",
                              metadata: ["profile": id, "error": error.localizedDescription])
            await attemptCLIFallback(reason: .usageUnauthorized, sourceError: error)
        } catch let error as AuthError {
            AppLogger.warning("Auth refresh failed",
                              metadata: ["profile": id, "error": error.localizedDescription])
            switch error {
            case .refreshExpired:
                await attemptCLIFallback(reason: .refreshExpired, sourceError: error)
            case .refreshReused:
                await attemptCLIFallback(reason: .refreshReused, sourceError: error)
            case .refreshRevoked:
                await attemptCLIFallback(reason: .refreshRevoked, sourceError: error)
            case .missingTokens:
                await attemptCLIFallback(reason: .missingTokens, sourceError: error)
            case .notFound:
                diagnostics.lastError = error.localizedDescription
                await finalize(.notSetUp, decision: "not-set-up")
            default:
                diagnostics.lastError = error.localizedDescription
                await finalize(.stale(cached), decision: "stale")
            }
        } catch {
            AppLogger.warning("Usage refresh failed",
                              metadata: ["profile": id, "error": error.localizedDescription])
            diagnostics.lastError = error.localizedDescription
            await finalize(.stale(cached), decision: "stale")
        }
    }

    private func canUseAuth(for id: String, activeProfileId: String) -> Bool {
        if id == activeProfileId {
            return self.store.liveAuthExists()
        }
        return self.store.authStoreExists(for: id)
    }
}
