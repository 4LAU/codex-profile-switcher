import Cocoa
import CodexProfileCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var store: ProfileStore!
    private var usageProvider: UsageProvider!
    private var periodicRefreshTimer: Timer?
    private var menu: PersistentActionMenu!
    private weak var refreshMenuItem: PersistentRefreshMenuItem?
    private var liveAuthWarning: LiveAuthWarning?
    private var lastLiveAuthMtime: Date?
    private var isMenuOpen = false
    private var menuRefreshRetryTask: Task<Void, Never>?
    private var hasPendingForcedRefresh = false
    private var hasPendingRecoveryNotice = false
    private var hasShownRecoveryNotice = false
    private var canHandleRecoveryNotices = false
    private let refreshPreferences = RefreshPreferences()
    private let sparkleUpdater = SparkleUpdater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        CoreLogger.configure { level, message, metadata in
            switch level {
            case .info:
                AppLogger.info(message, metadata: metadata)
            case .warning:
                AppLogger.warning(message, metadata: metadata)
            case .error:
                AppLogger.error(message, metadata: metadata)
            }
        }
        AppLogger.info("App launched", metadata: ["version": AppInfo.version])
        let decision = StartupIdentityGate.classify(
            bundleURL: Bundle.main.bundleURL,
            environment: ProcessInfo.processInfo.environment,
            realHome: FileManager.default.homeDirectoryForCurrentUser,
            hasDataProtectionKeychainAccess: ProcessSigningIdentity.hasDataProtectionKeychainAccess)
        let outcome = StartupIdentityGate.resolveRecovery(
            decision: decision,
            validateInstalledBundle: StartupIdentityGate.validateInstalledBundle,
            handoff: StartupIdentityGate.handoffToInstalledApp,
            scheduleTermination: { [weak self] in self?.scheduleRecoveryTermination() },
            continueStartup: { [weak self] in self?.continueStartup(decision: decision) },
            presentInvalidCandidate: { [weak self] in self?.presentRecoveryFailure() })
        guard outcome == .continued else { return }
    }

    private func continueStartup(decision: StartupIdentityGate.Decision) {
        self.canHandleRecoveryNotices = StartupIdentityGate.canHandleRecoveryNotice(
            decision: decision)
        if decision == .production {
            guard !self.terminateIfInstalledInstanceIsRunning() else { return }
            LaunchAtLogin.migrateLegacyLaunchAgentIfNeeded()
        }

        let environment = ProcessInfo.processInfo.environment
        if decision == .isolated {
            self.store = ProfileStore(
                authVault: StartupIdentityGate.makeIsolatedAuthVault(environment: environment),
                environment: environment)
        } else {
            self.store = ProfileStore(environment: environment)
        }
        self.usageProvider = UsageProvider(store: self.store)
        self.syncActiveProfile(force: true)

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.button?.image = IconRenderer.renderEmpty()
        self.statusItem.button?.imageScaling = .scaleNone

        self.menu = PersistentActionMenu(refreshAction: { [weak self] in
            self?.refreshAll()
        })
        self.menu.delegate = self
        self.statusItem.menu = self.menu
        if self.canHandleRecoveryNotices {
            self.registerRecoveryNoticeObserver()
        }

        self.registerWorkspaceObservers()
        self.usageProvider.onRefreshComplete = { [weak self] in
            self?.handleRefreshComplete()
        }
        self.requestRefresh()
        self.startPeriodicRefreshTimer()

        self.sparkleUpdater.startIfBundledApp()
        if self.canHandleRecoveryNotices {
            self.prepareRecoveryNoticeIfNeeded()
        }
    }

    private func terminateIfInstalledInstanceIsRunning() -> Bool {
        let installedBundleURL = StartupIdentityGate.installedBundleURL.standardizedFileURL
        let installedExecutableURL = installedBundleURL
            .appendingPathComponent("Contents/MacOS/CodexProfileSwitcher")
        let current = NSRunningApplication.current

        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.4lau.codex-profile-switcher")
            .filter { application in
                guard application.processIdentifier != current.processIdentifier,
                      let bundleURL = application.bundleURL,
                      let executableURL = application.executableURL else { return false }
                return Self.isLiteralURL(bundleURL, expected: installedBundleURL)
                    && Self.isLiteralURL(executableURL, expected: installedExecutableURL)
            }
            .filter { Self.launchedBefore($0, current) }
            .min { Self.launchedBefore($0, $1) }
        guard let running else { return false }

        AppLogger.info("Installed app is already running; activating it and terminating newcomer")
        _ = running.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return true
    }

    private static func launchedBefore(
        _ lhs: NSRunningApplication,
        _ rhs: NSRunningApplication
    ) -> Bool {
        if let lhsDate = lhs.launchDate,
           let rhsDate = rhs.launchDate,
           lhsDate != rhsDate {
            return lhsDate < rhsDate
        }
        return lhs.processIdentifier < rhs.processIdentifier
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isLiteralURL(_ url: URL, expected: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        return standardizedURL == expected
            && Self.canonicalURL(standardizedURL) == standardizedURL
    }

    deinit {
        self.periodicRefreshTimer?.invalidate()
        self.menuRefreshRetryTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard self.store != nil, self.usageProvider != nil else { return }
        self.isMenuOpen = true
        self.syncActiveProfile()
        self.rebuildMenu()
        if self.refreshPreferences.refreshWhenMenuOpens {
            self.requestRefresh(force: true)
            self.scheduleOpenMenuRefreshRetry()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        self.isMenuOpen = false
        if self.hasShownRecoveryNotice {
            if self.canHandleRecoveryNotices {
                StartupIdentityGate.acknowledgeRecoveryNotice()
            }
            self.hasPendingRecoveryNotice = false
            self.hasShownRecoveryNotice = false
        }
        self.menuRefreshRetryTask?.cancel()
        self.menuRefreshRetryTask = nil
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        self.refreshMenuItem?.setHighlighted(item === self.refreshMenuItem)
    }

    // MARK: - Timer

    private func startPeriodicRefreshTimer() {
        self.periodicRefreshTimer?.invalidate()
        self.periodicRefreshTimer = nil
        guard let interval = self.refreshPreferences.interval.timerInterval else { return }
        self.periodicRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.syncActiveProfile()
                self.requestRefresh()
            }
        }
    }

    private func registerWorkspaceObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(self.handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil)
    }

    @objc private func handleSystemWake() {
        guard self.store != nil, self.usageProvider != nil else { return }
        AppLogger.info("System woke; forcing usage refresh")
        self.syncActiveProfile(force: true)
        self.updateIcon()
        self.requestRefresh(force: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard self.store != nil, self.usageProvider != nil else { return }
        self.syncActiveProfile()
        self.requestRefresh()
    }

    private func handleRefreshComplete() {
        guard self.store != nil, self.usageProvider != nil else { return }
        if self.hasPendingForcedRefresh {
            self.hasPendingForcedRefresh = false
            self.requestRefresh(force: true)
        } else {
            self.refreshMenuItem?.setEnabled(true)
        }
        self.updateIcon()
        guard self.isMenuOpen else { return }
        self.rebuildMenu()
    }

    private func scheduleOpenMenuRefreshRetry() {
        self.menuRefreshRetryTask?.cancel()
        self.menuRefreshRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            guard self.isMenuOpen else { return }
            guard !self.usageProvider.isRefreshing else { return }
            guard self.hasDisplayedStaleOrLoadingProfiles() else { return }
            AppLogger.info("Retrying menu-open usage refresh because stale data is still visible")
            self.requestRefresh(force: true)
        }
    }

    private func hasDisplayedStaleOrLoadingProfiles() -> Bool {
        self.store.config.profiles.contains { profile in
            switch self.store.statuses[profile.id] ?? .notSetUp {
            case .loading, .stale:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Icon

    func updateIcon() {
        guard self.store != nil, self.statusItem != nil else { return }
        guard let activeId = self.store.liveProfileId else {
            self.statusItem.button?.image = IconRenderer.renderEmpty()
            return
        }

        if let snap = self.store.statuses[activeId]?.snapshot {
            self.statusItem.button?.image = IconRenderer.render(
                primaryPercent: snap.primaryUsedPercent,
                secondaryPercent: snap.secondaryUsedPercent)
        } else {
            self.statusItem.button?.image = IconRenderer.renderEmpty()
        }
    }

    // MARK: - Menu Construction

    private func rebuildMenu() {
        self.menu.removeAllItems()

        if self.hasPendingRecoveryNotice {
            let noticeItem = NSMenuItem(
                title: "Startup repaired — saved profiles unchanged",
                action: nil,
                keyEquivalent: "")
            noticeItem.isEnabled = false
            noticeItem.image = NSImage(
                systemSymbolName: "checkmark.circle.fill",
                accessibilityDescription: nil)
            self.menu.addItem(noticeItem)
            self.menu.addItem(.separator())
            if self.isMenuOpen {
                self.hasShownRecoveryNotice = true
            }
        }

        if let warning = self.liveAuthWarning {
            let warningItem = NSMenuItem(title: warning.message, action: nil, keyEquivalent: "")
            warningItem.isEnabled = false
            warningItem.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: nil)
            self.menu.addItem(warningItem)
            self.menu.addItem(.separator())
        }

        self.addUsageHeader()
        self.menu.addItem(.separator())

        let healthRecords = ProfileHealth.build(
            profiles: self.store.config.profiles,
            statuses: self.store.statuses,
            activeProfileId: self.store.liveProfileId,
            canActivateAuth: { id in self.store.authCanBeActivated(for: id) })
        var addedProfileSection = false
        var addedRecommendation = false

        if let activeHealth = healthRecords.first(where: \.isActive) {
            self.addProfileCard(for: activeHealth)
            addedProfileSection = true
        }

        if let recommendation = ProfileHealth.recommendation(from: healthRecords) {
            if addedProfileSection { self.menu.addItem(.separator()) }
            self.addRecommendationItem(for: recommendation)
            addedProfileSection = true
            addedRecommendation = true
        }

        let inactiveProfiles = ProfileHealth.menuOrderedInactive(healthRecords)
        if !inactiveProfiles.isEmpty {
            if addedProfileSection {
                if addedRecommendation {
                    self.menu.addItem(.separator())
                } else {
                    self.addProfileDivider()
                }
            }
            for (index, health) in inactiveProfiles.enumerated() {
                self.addProfileCard(for: health)
                if index != inactiveProfiles.indices.last {
                    self.addProfileDivider()
                }
            }
            addedProfileSection = true
        }

        if addedProfileSection {
            self.menu.addItem(.separator())
        }

        let refreshItem = self.menu.makeRefreshItem()
        refreshItem.setEnabled(!self.usageProvider.isRefreshing)
        self.refreshMenuItem = refreshItem
        self.menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(self.openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsItem.image?.size = NSSize(width: 13, height: 13)
        self.menu.addItem(settingsItem)

        self.sparkleUpdater.addMenuItem(to: self.menu)

        self.menu.addItem(.separator())

        let quitItem = NSMenuItem()
        quitItem.title = "Quit"
        quitItem.action = #selector(NSApplication.terminate(_:))
        quitItem.keyEquivalent = "q"
        quitItem.target = NSApp
        quitItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        quitItem.image?.size = NSSize(width: 13, height: 13)
        self.menu.addItem(quitItem)
    }

    private func prepareRecoveryNoticeIfNeeded() {
        guard self.canHandleRecoveryNotices else { return }
        let launchedForRecovery = ProcessInfo.processInfo.arguments.contains(
            StartupIdentityGate.recoveryLaunchArgument)
        let recoveredRunningInstance = StartupIdentityGate.hasPendingRecoveryNotice
        guard launchedForRecovery || recoveredRunningInstance else {
            return
        }
        self.hasPendingRecoveryNotice = true
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    private func registerRecoveryNoticeObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(self.handleRecoveryNotice),
            name: StartupIdentityGate.recoveryNoticeName,
            object: nil)
    }

    @objc private func handleRecoveryNotice(_ notification: Notification) {
        guard self.canHandleRecoveryNotices, self.store != nil, self.usageProvider != nil else { return }
        self.hasPendingRecoveryNotice = true
        if self.isMenuOpen {
            self.rebuildMenu()
        } else {
            self.statusItem.button?.performClick(nil)
        }
    }

    private func scheduleRecoveryTermination() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350)) {
            AppLogger.info("Recovery process terminating after installed-app handoff")
            NSApp.terminate(nil)
        }
    }

    private func presentRecoveryFailure() {
        let alert = NSAlert()
        alert.messageText = "Codex Profile Switcher needs the installed app"
        alert.informativeText =
            "Install and open the signed Codex Profile Switcher from /Applications, then try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func addProfileCard(for health: ProfileHealth) {
        let duplicateLine = self.duplicateSummary(for: health.profile.id)
        let cardView = ProfileCardView(
            profile: health.profile,
            status: health.status,
            isActive: health.isActive,
            duplicateLine: duplicateLine,
            onSwitch: { [weak self] in self?.switchToProfile(health.profile.id) })

        let hostView = NSHostingView(rootView: cardView)
        hostView.frame = NSRect(
            x: 0,
            y: 0,
            width: 290,
            height: self.cardHeight(for: health.status, hasDuplicate: duplicateLine != nil))

        let menuItem = NSMenuItem()
        menuItem.view = hostView
        self.menu.addItem(menuItem)
    }

    private func addUsageHeader() {
        let updatedAt = self.store.statuses.values
            .compactMap { $0.snapshot?.fetchedAt }
            .max()
        let header = UsageHeaderView(
            isRefreshing: self.usageProvider.isRefreshing,
            updatedAt: updatedAt)
        let hostView = NSHostingView(rootView: header)
        hostView.frame = NSRect(x: 0, y: 0, width: 290, height: 42)

        let menuItem = NSMenuItem()
        menuItem.view = hostView
        self.menu.addItem(menuItem)
    }

    private func addProfileDivider() {
        let divider = Color(nsColor: .separatorColor)
            .frame(height: 1)
            .padding(.horizontal, 14)
        let hostView = NSHostingView(rootView: divider)
        hostView.frame = NSRect(x: 0, y: 0, width: 290, height: 5)

        let menuItem = NSMenuItem()
        menuItem.view = hostView
        self.menu.addItem(menuItem)
    }

    private func addRecommendationItem(for health: ProfileHealth) {
        let score = health.score ?? 0
        let title = "⚡ Switch to \"\(health.profile.label)\" — \(score)% used"
        let item = NSMenuItem(title: title, action: #selector(self.switchToRecommendedProfile(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = health.profile.id
        item.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
        item.image?.size = NSSize(width: 13, height: 13)
        self.menu.addItem(item)
    }

    private func cardHeight(for status: ProfileStatus, hasDuplicate: Bool) -> CGFloat {
        var height: CGFloat
        switch status {
        case .available:
            height = 46
        case .stale(let snap) where snap != nil:
            height = 46
        case .reloginNeeded(let snap) where snap != nil:
            height = 58
        default:
            height = 36
        }

        if hasDuplicate { height += 14 }
        return height
    }

    private func duplicateSummary(for profileId: String) -> String? {
        let duplicates = self.store.duplicateProfileIDs(for: profileId)
        guard !duplicates.isEmpty else { return nil }
        let names = duplicates.map { duplicateId in
            self.store.config.profiles.first(where: { $0.id == duplicateId })?.label ?? "Profile \(duplicateId)"
        }
        if names.count == 1, let name = names.first {
            return "Same account as \(name)"
        }
        return "Same account as \(names.joined(separator: ", "))"
    }

    // MARK: - Profile Sync

    private func syncActiveProfile(force: Bool = false) {
        guard !self.store.isAuthMutationInProgress() else { return }

        if !force {
            let mtime = self.store.liveAuthModificationDate()
            if mtime == self.lastLiveAuthMtime { return }
            self.lastLiveAuthMtime = mtime
        } else {
            self.lastLiveAuthMtime = nil
        }

        let matches = self.store.matchingProfilesForLiveAuth()
        if matches.count == 1, let match = matches.first {
            self.store.setLiveProfileId(match)
            self.liveAuthWarning = nil
            if self.store.config.activeProfile != match {
                self.store.setActiveProfile(match)
            }
            return
        }

        if matches.count > 1 {
            let preferred = self.store.liveProfileId ?? self.store.config.activeProfile
            if !preferred.isEmpty, matches.contains(preferred) {
                self.store.setLiveProfileId(preferred)
                self.liveAuthWarning = nil
            } else {
                self.store.setLiveProfileId(nil)
                self.liveAuthWarning = .ambiguous
                AppLogger.warning("Live auth matched multiple saved profiles",
                                  metadata: ["matches": matches.joined(separator: ",")])
            }
            return
        }

        self.store.setLiveProfileId(nil)
        let allNotSetUp = self.store.statuses.values.allSatisfy {
            switch $0 {
            case .notSetUp: return true
            default: return false
            }
        }
        self.liveAuthWarning = self.store.liveAuthExists() && !allNotSetUp ? .unmanaged : nil
        if self.liveAuthWarning == .unmanaged {
            AppLogger.warning("Live auth does not match any saved profile")
        }
    }

    // MARK: - Actions

    @objc private func switchToRecommendedProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        self.switchToProfile(id)
    }

    private func switchToProfile(_ id: String) {
        self.menu.cancelTracking()
        AppLogger.info("Profile selected", metadata: ["profile": id])

        let isActive = id == self.store.liveProfileId
        let status = self.store.statuses[id]

        func startLogin() {
            self.startLogin(for: id, presentFailureAlert: true) { _ in
            }
        }

        switch status {
        case .notSetUp:
            startLogin()
            return
        case .reloginNeeded:
            if !self.store.authCanBeActivated(for: id) {
                AppLogger.warning("Profile requires login and has no saved auth; starting login",
                                  metadata: ["profile": id])
                startLogin()
                return
            }
        default:
            if isActive { return }
            if !self.store.authCanBeActivated(for: id) {
                AppLogger.warning("Profile has cached usage but no saved auth; starting login",
                                  metadata: ["profile": id])
                startLogin()
                return
            }
        }

        let profileLabel = self.store.config.profiles.first { $0.id == id }?.label ?? "Profile \(id)"
        let alert = NSAlert()
        alert.messageText = "Switch to \(profileLabel)?"
        alert.informativeText = "This will quit the current Codex instance and relaunch with the selected profile."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let storeRef = self.store!
        let workspacePath = self.store.relaunchWorkspacePath()
        storeRef.beginAuthMutation()
        Task { @MainActor [weak self] in
            let result = await CodexBridge.switchToProfile(id, workspacePath: workspacePath) {
                try storeRef.prepareProfileSwitch(
                    to: id,
                    isCodexDesktopRunning: CodexBridge.isCodexDesktopRunning)
            }
            storeRef.endAuthMutation()
            guard let self else { return }
            switch result {
            case .success:
                AppLogger.info("Profile switch succeeded", metadata: ["profile": id])
                self.store.setActiveProfile(id)
                self.store.setLiveProfileId(id)
                self.liveAuthWarning = nil
                self.requestRefresh(force: true)
                self.updateIcon()
                self.rebuildMenu()
            case .failure(let error):
                self.syncActiveProfile(force: true)
                self.updateIcon()
                switch error {
                case .switchCommittedButLaunchFailed:
                    self.presentBridgeError(title: "Profile switched", message: error.localizedDescription)
                default:
                    self.presentBridgeError(title: "Switch failed", message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func refreshAll() {
        self.syncActiveProfile(force: true)
        self.requestRefresh(force: true)
    }

    private func requestRefresh(force: Bool = false) {
        if self.usageProvider.isRefreshing {
            if force {
                self.hasPendingForcedRefresh = true
            }
            self.refreshMenuItem?.setEnabled(false)
            return
        }
        self.refreshMenuItem?.setEnabled(false)
        self.usageProvider.refreshAll(force: force)
        self.refreshMenuItem?.setEnabled(!self.usageProvider.isRefreshing)
        if self.isMenuOpen {
            self.rebuildMenu()
        }
    }

    @objc private func openSettings() {
        self.menu.cancelTracking()
        SettingsWindow.show(
            store: self.store,
            refreshPreferences: self.refreshPreferences,
            actions: SettingsActions(
                reauthenticateProfile: { [weak self] (id: String, completion: @escaping (Result<Void, SettingsActionError>) -> Void) in
                    self?.startLogin(for: id, presentFailureAlert: false) { result in
                        completion(result.mapError { SettingsActionError(message: $0.localizedDescription) })
                    }
                },
                cancelLogin: { id in
                    CodexBridge.cancelLogin(profileId: id)
                },
                clearSavedAuth: { [weak self] (id: String) in
                    guard let self else {
                        return .failure(SettingsActionError(message: "Settings window is unavailable."))
                    }
                    return self.clearSavedAuth(for: id)
                },
                refreshScheduleChanged: { [weak self] in
                    self?.startPeriodicRefreshTimer()
                },
                reviewLegacyKeychainMigration: { [weak self] in
                    guard let self else {
                        return .failure(SettingsActionError(message: "Settings window is unavailable."))
                    }
                    do {
                        return .success(try self.store.reviewLegacyKeychainMigration())
                    } catch {
                        return .failure(SettingsActionError(message: error.localizedDescription))
                    }
                },
                confirmLegacyKeychainMigration: { [weak self] preview, approvedCount in
                    guard let self else {
                        return .failure(SettingsActionError(message: "Settings window is unavailable."))
                    }
                    do {
                        try self.store.confirmLegacyKeychainMigration(preview, approvedCount: approvedCount)
                        return .success(())
                    } catch {
                        return .failure(SettingsActionError(message: error.localizedDescription))
                    }
                },
                completePendingKeychainMigration: { [weak self] preview, approvedCount in
                    guard let self else {
                        return .failure(SettingsActionError(message: "Settings window is unavailable."))
                    }
                    do {
                        try self.store.completePendingKeychainMigration(preview, approvedCount: approvedCount)
                        return .success(())
                    } catch {
                        return .failure(SettingsActionError(message: error.localizedDescription))
                    }
                },
                cancelLegacyKeychainMigrationReview: { [weak self] preview in
                    self?.store.cancelLegacyKeychainMigrationReview(preview)
                }))
    }

    private func presentBridgeError(title: String, message: String?) {
        AppLogger.error(title, metadata: ["message": message ?? "Unknown error"])
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message ?? "Unknown error"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func startLogin(
        for profileId: String,
        presentFailureAlert: Bool,
        completion: ((Result<Void, CodexBridgeError>) -> Void)? = nil
    ) {
        let store = self.store!
        store.beginAuthMutation()
        CodexBridge.startLogin(profileId: profileId) { [weak self] result in
            guard let self else {
                store.endAuthMutation()
                return
            }

            let finalResult: Result<Void, CodexBridgeError>

            switch result {
            case .success:
                AppLogger.info("Login succeeded", metadata: ["profile": profileId])
                if self.store.liveProfileId == profileId {
                    do {
                        try self.store.syncSavedAuthToLive(for: profileId)
                    } catch {
                        AppLogger.error("Failed to update live auth after login",
                                        metadata: ["profile": profileId, "error": error.localizedDescription])
                        store.endAuthMutation()
                        let failure = CodexBridgeError.stateUpdateFailed(
                            "Login succeeded but the active profile could not update live auth: \(error.localizedDescription)")
                        if presentFailureAlert {
                            self.presentBridgeError(title: "Login failed", message: failure.localizedDescription)
                        }
                        completion?(.failure(failure))
                        return
                    }
                }
                store.endAuthMutation()
                self.syncActiveProfile(force: true)
                self.requestRefresh(force: true)
                self.updateIcon()
                finalResult = .success(())
            case .failure(let error):
                store.endAuthMutation()
                if presentFailureAlert && !error.isUserCancelled {
                    self.presentBridgeError(title: "Login failed", message: error.localizedDescription)
                }
                finalResult = .failure(error)
            }

            completion?(finalResult)
        }
    }

    private func clearSavedAuth(for profileId: String) -> Result<Void, SettingsActionError> {
        do {
            self.hasPendingForcedRefresh = false
            self.usageProvider.cancelRefreshes()
            try self.store.clearSavedAuth(for: profileId)
            self.syncActiveProfile(force: true)
            self.requestRefresh(force: true)
            self.updateIcon()
            return .success(())
        } catch {
            return .failure(SettingsActionError(message: error.localizedDescription))
        }
    }
}

// MARK: - Settings Window
