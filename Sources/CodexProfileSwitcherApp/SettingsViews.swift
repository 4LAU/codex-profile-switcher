import Cocoa
import CodexProfileCore
import ServiceManagement
import SwiftUI

struct SettingsActions {
    let reauthenticateProfile: (String, @escaping (Result<Void, SettingsActionError>) -> Void) -> Void
    let cancelLogin: (String) -> Bool
    let clearSavedAuth: (String) -> Result<Void, SettingsActionError>
    let refreshScheduleChanged: () -> Void
    let reviewLegacyKeychainMigration: () -> Result<KeychainMigrationPreview, SettingsActionError>
    let confirmLegacyKeychainMigration: (KeychainMigrationPreview, Int) -> Result<Void, SettingsActionError>
    let completePendingKeychainMigration: (KeychainMigrationPreview, Int) -> Result<Void, SettingsActionError>
    let cancelLegacyKeychainMigrationReview: (KeychainMigrationPreview) -> Void
}

enum SettingsWindow {
    private static var windowController: NSWindowController?
    private static var windowDelegate: SettingsWindowDelegate?
    private static var migrationLifecycle: SettingsMigrationLifecycle?

    static func show(
        store: ProfileStore,
        refreshPreferences: RefreshPreferences,
        actions: SettingsActions
    ) {
        Self.cancelActiveMigrationReview()
        let lifecycle = SettingsMigrationLifecycle()
        Self.migrationLifecycle = lifecycle

        if let wc = Self.windowController {
            wc.window?.contentView = NSHostingView(
                rootView: SettingsView(
                    store: store,
                    refreshPreferences: refreshPreferences,
                    actions: actions,
                    migrationLifecycle: lifecycle))
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        let windowDelegate = SettingsWindowDelegate { Self.cancelActiveMigrationReview() }
        window.delegate = windowDelegate
        Self.windowDelegate = windowDelegate

        let view = SettingsView(
            store: store,
            refreshPreferences: refreshPreferences,
            actions: actions,
            migrationLifecycle: lifecycle)
        window.contentView = NSHostingView(rootView: view)

        let wc = NSWindowController(window: window)
        Self.windowController = wc
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func cancelActiveMigrationReview() {
        Self.migrationLifecycle?.cancelActiveMigrationReview()
    }
}

private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        self.onClose()
    }
}

final class SettingsMigrationLifecycle {
    private var preview: KeychainMigrationPreview?
    private var cancel: ((KeychainMigrationPreview) -> Void)?

    func begin(
        _ preview: KeychainMigrationPreview,
        cancel: @escaping (KeychainMigrationPreview) -> Void
    ) {
        self.preview = preview
        self.cancel = cancel
    }

    func finish(_ preview: KeychainMigrationPreview) {
        guard self.preview == preview else { return }
        self.preview = nil
        self.cancel = nil
    }

    func cancelMigrationReview(_ preview: KeychainMigrationPreview) {
        guard self.preview == preview, let cancel = self.cancel else { return }
        self.preview = nil
        self.cancel = nil
        cancel(preview)
    }

    func cancelActiveMigrationReview() {
        guard let preview = self.preview else { return }
        self.cancelMigrationReview(preview)
    }
}

struct SettingsView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var refreshPreferences: RefreshPreferences
    let actions: SettingsActions
    let migrationLifecycle: SettingsMigrationLifecycle
    @State private var selectedTab = 0
    @StateObject private var toast = ToastState()

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Picker("", selection: self.$selectedTab) {
                    Label("Profiles", systemImage: "person.2").tag(0)
                    Label("General", systemImage: "gearshape").tag(1)
                    Label("About", systemImage: "info.circle").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()

                switch self.selectedTab {
                case 0: ProfilesTab(store: self.store, actions: self.actions, toast: self.toast)
                case 1:
                    GeneralTab(
                        store: self.store,
                        refreshPreferences: self.refreshPreferences,
                        actions: self.actions,
                        migrationLifecycle: self.migrationLifecycle,
                        toast: self.toast)
                case 2: AboutTab()
                default: EmptyView()
                }
            }

            ToastOverlay(state: self.toast)
        }
    }
}

struct ProfilesTab: View {
    @ObservedObject var store: ProfileStore
    let actions: SettingsActions
    @ObservedObject var toast: ToastState
    @State private var selectedId: String?
    @State private var labelDraft = ProfileLabelDraft()
    @State private var profiles: [ProfileConfig] = []
    @State private var pendingDeleteId: String?
    @State private var pendingClearAuthId: String?
    @State private var actionInFlight: Set<String> = []
    @State private var refreshTick = 0
    @FocusState private var labelFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            self.sidebar
            Divider()
            self.detailPanel
        }
        .onAppear {
            self.profiles = self.store.config.profiles
            self.selectedId = self.store.liveProfileId ?? self.profiles.first?.id
            self.syncEditingLabel()
        }
        .onDisappear { self.commitLabel() }
        .alert("Delete Profile", isPresented: Binding(
            get: { self.pendingDeleteId != nil },
            set: { if !$0 { self.pendingDeleteId = nil } }
        )) {
            Button("Cancel", role: .cancel) { self.pendingDeleteId = nil }
            Button("Delete", role: .destructive) {
                if let id = self.pendingDeleteId {
                    let label = self.profileLabel(id)
                    if self.removeProfile(id) {
                        self.toast.show("Deleted \(label)", style: .info)
                    }
                }
                self.pendingDeleteId = nil
            }
        } message: {
            if let id = self.pendingDeleteId {
                Text("Are you sure you want to delete \"\(self.profileLabel(id))\"? This cannot be undone.")
            }
        }
        .confirmationDialog("Clear Saved Auth", isPresented: Binding(
            get: { self.pendingClearAuthId != nil },
            set: { if !$0 { self.pendingClearAuthId = nil } }
        )) {
            Button("Cancel", role: .cancel) { self.pendingClearAuthId = nil }
            Button("Clear", role: .destructive) {
                if let id = self.pendingClearAuthId {
                    self.clearSavedAuth(id)
                }
                self.pendingClearAuthId = nil
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: self.$selectedId) {
                Section("Profiles") {
                    ForEach(self.profiles) { profile in
                        self.sidebarRow(profile)
                            .tag(profile.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: self.selectedId) { _, _ in
                self.commitLabel()
                self.syncEditingLabel()
            }

            Divider()

            HStack(spacing: 0) {
                Button(action: self.addProfile) {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)

                Divider().frame(height: 14)

                Button {
                    if let id = self.selectedId { self.pendingDeleteId = id }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(
                    self.selectedId == nil
                        || self.selectedId == self.store.liveProfileId
                        || self.selectedId == self.store.config.activeProfile)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(width: 200)
    }

    @ViewBuilder
    private func sidebarRow(_ profile: ProfileConfig) -> some View {
        let details = self.store.authDetails(for: profile.id)
        let isActive = self.store.liveProfileId == profile.id
        let hasSavedAuth = self.store.authStoreExists(for: profile.id)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(profile.label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if isActive {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                }
            }
            Text(hasSavedAuth ? (details?.menuSummary ?? "Authenticated") : "Not set up")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .id("\(profile.id)-\(self.refreshTick)")
    }

    // MARK: - Detail Panel

    @ViewBuilder
    private var detailPanel: some View {
        if let id = self.selectedId,
           let profile = self.profiles.first(where: { $0.id == id }) {
            self.profileDetail(profile)
        } else {
            Text("No profile selected")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func profileDetail(_ profile: ProfileConfig) -> some View {
        let details = self.store.authDetails(for: profile.id)
        let hasSavedAuth = self.store.authStoreExists(for: profile.id)
        let isActive = self.store.liveProfileId == profile.id
        let status = self.store.statuses[profile.id] ?? .notSetUp
        let loginRunning = CodexBridge.isLoginRunning(profileId: profile.id)
        let inFlight = self.actionInFlight.contains(profile.id) || loginRunning
        let duplicates = self.store.duplicateProfileIDs(for: profile.id)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !duplicates.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.warning)
                            .font(.system(size: 12))
                        Text("Same account as \(self.duplicateNames(for: duplicates))")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.warning)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Label:")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    TextField("", text: self.$labelDraft.text)
                        .textFieldStyle(.roundedBorder)
                        .focused(self.$labelFieldFocused)
                        .onSubmit { self.commitLabel() }
                        .onExitCommand { self.syncEditingLabel() }
                        .onChange(of: self.labelFieldFocused) { _, focused in
                            if !focused { self.commitLabel() }
                        }
                        .disabled(inFlight)
                }

                if hasSavedAuth {
                    if let details {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Account:")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(details.settingsTitle)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)

                                if !details.settingsDetails.isEmpty,
                                   details.settingsDetails != "No additional identity details" {
                                    Text(details.settingsDetails)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Status:")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                        // Baseline-aligned, not centred: the enclosing row anchors
                        // on this group's first baseline, and a centred group
                        // reports a different baseline once the 12pt "(active)"
                        // sits beside the 13pt label. That shifted the whole row
                        // and everything below it on the active profile only.
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle()
                                .fill(self.statusColor(for: status))
                                .frame(width: 7, height: 7)
                                // A shape has no baseline of its own; without a
                                // guide it would hang from its bottom edge. Half
                                // the 13pt label's x-height puts the dot's centre
                                // on the centre of the lowercase text.
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
                            Text(self.statusLabel(for: status))
                                .font(.system(size: 13))
                            if isActive {
                                Text("(active)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if loginRunning {
                            Button("Cancel Login") { self.cancelLogin(profile.id) }
                        } else {
                            Button("Set Up") { self.reauthenticate(profile.id) }
                                .disabled(inFlight)
                        }
                        Text("Link your OpenAI account to start tracking usage.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 68)
                }

                if hasSavedAuth {
                    HStack(spacing: 8) {
                        if loginRunning {
                            Button("Cancel Login") { self.cancelLogin(profile.id) }
                        } else {
                            Button("Re-authenticate\u{2026}") {
                                self.reauthenticate(profile.id)
                            }
                            .disabled(inFlight)
                        }

                        Button("Clear Auth\u{2026}") { self.pendingClearAuthId = profile.id }
                            .disabled(inFlight || isActive)
                    }
                    .padding(.leading, 68)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Actions

    private func syncEditingLabel() {
        self.labelDraft.sync(selectedId: self.selectedId, profiles: self.profiles)
    }

    private func commitLabel() {
        guard let value = self.labelDraft.commitValue() else { return }
        self.store.updateLabel(for: value.id, label: value.label)
        self.profiles = self.store.config.profiles
    }

    private func addProfile() {
        self.commitLabel()
        let profile = self.store.addProfile()
        self.profiles = self.store.config.profiles
        self.selectedId = profile.id
        self.syncEditingLabel()
        self.toast.show("Added \(profile.label)", style: .success)
    }

    private func removeProfile(_ id: String) -> Bool {
        do {
            try self.store.removeProfile(id)
            self.profiles = self.store.config.profiles
            if self.selectedId == id {
                self.selectedId = self.profiles.first?.id
                self.syncEditingLabel()
            }
            return true
        } catch {
            self.toast.show(error.localizedDescription, style: .error)
            return false
        }
    }

    private func reauthenticate(_ profileId: String) {
        self.commitLabel()
        self.actionInFlight.insert(profileId)
        self.actions.reauthenticateProfile(profileId) { result in
            DispatchQueue.main.async(execute: {
                self.actionInFlight.remove(profileId)
                self.refreshTick += 1
                self.profiles = self.store.config.profiles
                self.syncEditingLabel()
                switch result {
                case .success:
                    self.toast.show("Updated auth for \(self.profileLabel(profileId))", style: .success)
                case .failure(let error):
                    self.toast.show(error.localizedDescription, style: .error)
                }
            })
        }
    }

    private func cancelLogin(_ profileId: String) {
        if self.actions.cancelLogin(profileId) {
            self.actionInFlight.remove(profileId)
            self.refreshTick += 1
            self.toast.show("Cancelled login for \(self.profileLabel(profileId))", style: .info)
        }
    }

    private func clearSavedAuth(_ profileId: String) {
        switch self.actions.clearSavedAuth(profileId) {
        case .success:
            self.refreshTick += 1
            self.profiles = self.store.config.profiles
            self.syncEditingLabel()
            self.toast.show("Cleared auth for \(self.profileLabel(profileId))", style: .info)
        case .failure(let error):
            self.toast.show(error.localizedDescription, style: .error)
        }
    }

    private func profileLabel(_ id: String) -> String {
        self.profiles.first(where: { $0.id == id })?.label ?? "Profile \(id)"
    }

    private func duplicateNames(for duplicates: [String]) -> String {
        let names = duplicates.map { self.profileLabel($0) }
        return names.count == 1 ? (names.first ?? "") : names.joined(separator: ", ")
    }

    private func statusLabel(for status: ProfileStatus) -> String {
        switch status {
        case .available: return "Ready"
        case .loading: return "Refreshing"
        case .stale: return "Cached"
        case .reloginNeeded: return "Re-login needed"
        case .notSetUp: return "Not set up"
        }
    }

    private func statusColor(for status: ProfileStatus) -> Color {
        switch status {
        case .available: return Palette.success
        case .loading: return Palette.accent
        case .stale: return .secondary
        case .reloginNeeded: return Palette.warning
        case .notSetUp: return .secondary.opacity(0.5)
        }
    }
}

struct GeneralTab: View {
    let store: ProfileStore
    @ObservedObject var refreshPreferences: RefreshPreferences
    let actions: SettingsActions
    let migrationLifecycle: SettingsMigrationLifecycle
    @ObservedObject var toast: ToastState
    @State private var launchAtLoginState = LaunchAtLogin.state
    @State private var renewalAgentState = RenewalAgent.state
    @State private var migrationSheet: KeychainMigrationSheet?
    @State private var migrationError: String?
    @State private var isReviewingMigration = false
    @State private var isMigrationActionInFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("STARTUP")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: {
                            self.launchAtLoginState == .enabled || self.launchAtLoginState == .requiresApproval
                        },
                        set: self.setLaunchAtLogin))
                    .disabled(self.launchAtLoginState == .unavailable)
                    .accessibilityValue(self.launchAtLoginAccessibilityValue)

                self.launchAtLoginDescription

                HStack {
                    Text("Credential renewal")
                    Spacer()
                    Text(self.renewalAgentStatus)
                        .foregroundStyle(.secondary)
                }

                self.renewalAgentDescription
                Text("A Mac that stays powered off for more than 10 days comes back needing a manual sign-in, and nothing local prevents that.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("REFRESHING")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Picker("Refresh interval", selection: self.$refreshPreferences.interval) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(self.refreshIntervalLabel(interval)).tag(interval)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: self.refreshPreferences.interval) { _, _ in
                    self.actions.refreshScheduleChanged()
                }

                Toggle(
                    "Refresh when the menu opens",
                    isOn: self.$refreshPreferences.refreshWhenMenuOpens)

                if self.refreshPreferences.interval == .manual {
                    Text("Automatic background refresh is off. Refresh from the menu or press Command-R.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            if self.store.shouldShowKeychainMigration {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("KEYCHAIN MIGRATION")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Button("Review Legacy Keychain Copies\u{2026}") {
                        self.reviewLegacyKeychainMigration()
                    }
                    .disabled(self.isReviewingMigration || self.isMigrationActionInFlight)

                    Text("Move saved accounts from an older app version after reviewing each copy.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("SUPPORT")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        DebugInfoBuilder.copyToPasteboard(store: self.store)
                        self.toast.show("Copied debug info", style: .success)
                    } label: {
                        Label("Copy Debug Info", systemImage: "doc.on.doc")
                    }

                    Button {
                        DebugInfoBuilder.openLogFile()
                    } label: {
                        Label("Open Log", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Button {
                    DebugInfoBuilder.reportBug()
                } label: {
                    Label("Report Bug", systemImage: "exclamationmark.bubble")
                }

                Text(AppLogger.logURL.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            self.refreshLaunchAtLoginState()
            self.refreshRenewalAgentState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.refreshLaunchAtLoginState()
            self.refreshRenewalAgentState()
        }
        .onDisappear { self.cancelLegacyKeychainMigrationReview() }
        .sheet(item: self.migrationSheetBinding) { sheet in
            KeychainMigrationConfirmationSheet(
                title: sheet.title,
                candidates: sheet.candidates,
                isDestructive: sheet.isDestructive,
                isActionInFlight: self.isMigrationActionInFlight,
                onCancel: self.cancelLegacyKeychainMigrationReview,
                onConfirm: { self.confirmLegacyKeychainMigration(sheet) }
            )
        }
        .alert("Keychain Migration", isPresented: Binding(
            get: { self.migrationError != nil },
            set: { if !$0 { self.migrationError = nil } }
        )) {
            Button("OK", role: .cancel) { self.migrationError = nil }
        } message: {
            Text(self.migrationError ?? "")
        }
    }

    private var migrationSheetBinding: Binding<KeychainMigrationSheet?> {
        Binding(
            get: { self.migrationSheet },
            set: { sheet in
                guard sheet == nil else {
                    self.migrationSheet = sheet
                    return
                }
                self.cancelLegacyKeychainMigrationReview()
            })
    }

    private func reviewLegacyKeychainMigration() {
        self.isReviewingMigration = true
        defer { self.isReviewingMigration = false }

        switch self.actions.reviewLegacyKeychainMigration() {
        case let .success(preview):
            if preview.candidateCount > 0 {
                self.migrationLifecycle.begin(
                    preview,
                    cancel: self.actions.cancelLegacyKeychainMigrationReview)
                self.migrationSheet = KeychainMigrationSheet(preview: preview, kind: .moveAndRemove)
            } else if preview.pendingCompletionCount > 0 {
                self.migrationLifecycle.begin(
                    preview,
                    cancel: self.actions.cancelLegacyKeychainMigrationReview)
                self.migrationSheet = KeychainMigrationSheet(preview: preview, kind: .completePending)
            } else {
                self.actions.cancelLegacyKeychainMigrationReview(preview)
                self.toast.show("No legacy Keychain copies need migration", style: .info)
            }
        case let .failure(error):
            self.clearMigrationUIWithError(error)
        }
    }

    private func confirmLegacyKeychainMigration(_ sheet: KeychainMigrationSheet) {
        self.isMigrationActionInFlight = true
        defer { self.isMigrationActionInFlight = false }

        let result: Result<Void, SettingsActionError>
        switch sheet.kind {
        case .moveAndRemove:
            result = self.actions.confirmLegacyKeychainMigration(
                sheet.preview,
                sheet.preview.candidateCount)
        case .completePending:
            result = self.actions.completePendingKeychainMigration(
                sheet.preview,
                sheet.preview.pendingCompletionCount)
        }

        switch result {
        case .success:
            self.migrationLifecycle.finish(sheet.preview)
            self.migrationSheet = nil
            self.toast.show(sheet.successMessage, style: .success)
        case let .failure(error):
            self.clearMigrationUIWithError(error)
        }
    }

    private func cancelLegacyKeychainMigrationReview() {
        guard let sheet = self.migrationSheet else { return }
        self.migrationSheet = nil
        self.migrationLifecycle.cancelMigrationReview(sheet.preview)
    }

    private func clearMigrationUIWithError(_ error: SettingsActionError) {
        if let preview = self.migrationSheet?.preview {
            self.migrationLifecycle.cancelMigrationReview(preview)
        }
        self.migrationSheet = nil
        self.migrationError = error.localizedDescription
    }

    private func refreshIntervalLabel(_ interval: RefreshInterval) -> String {
        switch interval {
        case .manual: return "Manual"
        case .oneMinute: return "1 min"
        case .twoMinutes: return "2 min"
        case .fiveMinutes: return "5 min"
        case .fifteenMinutes: return "15 min"
        }
    }

    @ViewBuilder
    private var launchAtLoginDescription: some View {
        switch self.launchAtLoginState {
        case .enabled:
            Text("Opens automatically when your Mac starts.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        case .disabled:
            Text("Does not open automatically when your Mac starts.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        case .requiresApproval:
            VStack(alignment: .leading, spacing: 6) {
                Text("macOS is waiting for approval.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Open Login Items") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .buttonStyle(.link)
            }
        case .unavailable:
            Text("The signed app in /Applications owns Launch at Login. Isolated development builds cannot change it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var launchAtLoginAccessibilityValue: String {
        switch self.launchAtLoginState {
        case .enabled: return "On"
        case .disabled: return "Off"
        case .requiresApproval: return "On, waiting for approval"
        case .unavailable: return "Unavailable"
        }
    }

    @ViewBuilder
    private var renewalAgentDescription: some View {
        switch self.renewalAgentState {
        case .enabled:
            Text("Runs daily in the background, even when the app is closed.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        case .disabled:
            Text("Renewal is not scheduled.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .requiresApproval:
            VStack(alignment: .leading, spacing: 6) {
                Text("Renewal is not scheduled; macOS is waiting for approval.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Open Login Items") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .buttonStyle(.link)
            }
        case .unavailable:
            Text("The signed app in /Applications owns renewal scheduling. Isolated development builds cannot change it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var renewalAgentStatus: String {
        switch self.renewalAgentState {
        case .enabled: return "Scheduled"
        case .disabled, .requiresApproval: return "Not scheduled"
        case .unavailable: return "Unavailable"
        }
    }

    private func refreshLaunchAtLoginState() {
        self.launchAtLoginState = LaunchAtLogin.state
    }

    private func refreshRenewalAgentState() {
        self.renewalAgentState = RenewalAgent.state
    }

    private func setLaunchAtLogin(_ isOn: Bool) {
        let previousState = self.launchAtLoginState
        self.launchAtLoginState = isOn ? .enabled : .disabled

        do {
            if isOn {
                try LaunchAtLogin.enable()
            } else {
                try LaunchAtLogin.disable()
            }
            self.refreshLaunchAtLoginState()
        } catch {
            self.launchAtLoginState = previousState
            self.toast.show(error.localizedDescription, style: .error)
        }
    }
}

private struct KeychainMigrationSheet: Identifiable {
    enum Kind {
        case moveAndRemove
        case completePending
    }

    let id = UUID()
    let preview: KeychainMigrationPreview
    let kind: Kind

    var candidates: [KeychainMigrationCandidate] {
        switch self.kind {
        case .moveAndRemove:
            self.preview.candidates
        case .completePending:
            self.preview.pendingCompletionCandidates
        }
    }

    var title: String {
        switch self.kind {
        case .moveAndRemove:
            "Move and remove \(self.preview.candidateCount) legacy Keychain copies"
        case .completePending:
            "Complete \(self.preview.pendingCompletionCount) verified Keychain migrations"
        }
    }

    var isDestructive: Bool {
        self.kind == .moveAndRemove
    }

    var successMessage: String {
        switch self.kind {
        case .moveAndRemove:
            "Moved \(self.preview.candidateCount) legacy Keychain copies"
        case .completePending:
            "Completed \(self.preview.pendingCompletionCount) Keychain migrations"
        }
    }
}

private struct KeychainMigrationConfirmationSheet: View {
    let title: String
    let candidates: [KeychainMigrationCandidate]
    let isDestructive: Bool
    let isActionInFlight: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(self.title)
                .font(.system(size: 17, weight: .semibold))

            Text(self.isDestructive
                 ? "Each listed copy will be verified in the new Keychain before its older copy is removed."
                 : "Each listed account already has a verified new Keychain copy. This only records that migration is complete.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            List(self.candidates) { candidate in
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.label)
                        .font(.system(size: 13, weight: .medium))
                    Text("Profile ID: \(candidate.id)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 140, maxHeight: 260)

            HStack {
                Spacer()
                Button("Cancel") { self.onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(self.isActionInFlight)
                Button(self.isDestructive ? "Move and Remove" : "Mark Complete",
                       role: self.isDestructive ? .destructive : nil) {
                    self.onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(self.isActionInFlight)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text(AppInfo.name)
                .font(.system(size: 16, weight: .bold))

            Text("Version \(AppInfo.version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("Switch between OpenAI Codex accounts\nfrom your menu bar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider().padding(.horizontal, 40)

            Text("MIT License")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Launch at Login
