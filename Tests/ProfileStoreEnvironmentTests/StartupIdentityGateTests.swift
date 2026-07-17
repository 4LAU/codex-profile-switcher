@testable import CodexProfileCore
@testable import CodexProfileSwitcherApp
import Foundation
import Testing

struct StartupIdentityGateTests {
    private let installedBundle = URL(fileURLWithPath: "/Applications/CodexProfileSwitcher.app")
    private let realHome = URL(fileURLWithPath: "/Users/tester")

    @Test
    func installedProductionBuildUsesProductionIdentity() throws {
        let exactAccessGroup = KeychainAccessGroupResolver.resolve(
            accessGroupsEntitlement: [KeychainAccessGroupResolver.dataProtectionAccessGroup])
        let result = StartupIdentityGate.classify(
            bundleURL: self.installedBundle,
            environment: [:],
            realHome: self.realHome,
            hasDataProtectionKeychainAccess: exactAccessGroup != nil)

        try envExpect(result == .production,
                      "The signed installed build with the production capability must continue")
    }

    @Test
    func installedBuildWithoutProductionCapabilityRequiresRecovery() throws {
        let result = StartupIdentityGate.classify(
            bundleURL: self.installedBundle,
            environment: [:],
            realHome: self.realHome,
            hasDataProtectionKeychainAccess: false)

        try envExpect(result == .recovery,
                      "The installed bundle without the production capability must recover")
    }

    @Test
    func profileHomeOverrideUsesIsolatedIdentity() throws {
        let result = StartupIdentityGate.classify(
            bundleURL: URL(fileURLWithPath: "/tmp/dev/CodexProfileSwitcher.app"),
            environment: ["CODEX_PROFILE_HOME": "/tmp/profile-home-isolated"],
            realHome: self.realHome,
            hasDataProtectionKeychainAccess: false)

        try envExpect(result == .isolated,
                      "A distinct CODEX_PROFILE_HOME must remain isolated")
    }

    @Test
    func profileTestHomeOverrideUsesIsolatedIdentity() throws {
        let result = StartupIdentityGate.classify(
            bundleURL: URL(fileURLWithPath: "/tmp/dev/CodexProfileSwitcher.app"),
            environment: ["CODEX_PROFILE_TEST_HOME": "/tmp/profile-test-home-isolated"],
            realHome: self.realHome,
            hasDataProtectionKeychainAccess: false)

        try envExpect(result == .isolated,
                      "A distinct CODEX_PROFILE_TEST_HOME must remain isolated")
    }

    @Test
    func uninstalledProductionCapabilityRequiresRecovery() throws {
        let result = StartupIdentityGate.classify(
            bundleURL: URL(fileURLWithPath: "/tmp/dev/codex-profile-switcher"),
            environment: [:],
            realHome: self.realHome,
            hasDataProtectionKeychainAccess: true)

        try envExpect(result == .recovery,
                      "A capable process outside the installed bundle must recover")
    }

    @Test
    func overrideCanonicalizingToRealHomeRequiresRecovery() throws {
        let aliasOfRealHome = self.realHome
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent(self.realHome.lastPathComponent, isDirectory: true)
            .path
        let result = StartupIdentityGate.classify(
            bundleURL: URL(fileURLWithPath: "/tmp/dev/codex-profile-switcher"),
            environment: ["CODEX_PROFILE_HOME": aliasOfRealHome],
            realHome: self.realHome,
            hasDataProtectionKeychainAccess: true)

        try envExpect(result == .recovery,
                      "An override resolving to the real home must recover")
    }

    @Test
    func overrideSymlinkResolvingToRealHomeRequiresRecovery() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("startup-identity-gate-" + UUID().uuidString, isDirectory: true)
        let realHomeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let realHome = URL(fileURLWithPath: realHomeDirectory.path)
        let alias = root.appendingPathComponent("home-alias", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: realHomeDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: alias.path, withDestinationPath: realHomeDirectory.path)

        let result = StartupIdentityGate.classify(
            bundleURL: URL(fileURLWithPath: "/tmp/dev/codex-profile-switcher"),
            environment: ["CODEX_PROFILE_HOME": alias.path],
            realHome: realHome,
            hasDataProtectionKeychainAccess: true)

        try envExpect(result == .recovery,
                      "A symlink override resolving to the real home must recover")
    }

    @Test
    func recoveryValidatesInstalledTargetAndNeverContinues() throws {
        var events: [String] = []
        var validatedURL: URL?
        var handedOffURL: URL?
        let decision = StartupIdentityGate.classify(
            bundleURL: URL(fileURLWithPath: "/tmp/dev/codex-profile-switcher"),
            environment: [:],
            realHome: self.realHome,
            hasDataProtectionKeychainAccess: true)
        let outcome = StartupIdentityGate.resolveRecovery(
            decision: decision,
            validateInstalledBundle: { url in
                validatedURL = url
                events.append("validate")
                return true
            },
            handoff: { url, completion in
                events.append("handoff")
                handedOffURL = url
                completion(true)
            },
            scheduleTermination: {
                events.append("terminate")
            },
            continueStartup: {
                events.append("continue")
            })

        try envExpect(outcome == .handedOff, "Recovery did not report a successful handoff")
        try envExpect(decision == .recovery, "A non-installed normal-home process did not enter recovery")
        try envExpect(validatedURL == self.installedBundle,
                      "Recovery did not validate the fixed installed bundle")
        try envExpect(handedOffURL == self.installedBundle,
                      "Recovery handed off to a non-installed candidate")
        try envExpect(events == ["validate", "handoff", "terminate"],
                      "Recovery reached ProfileStore continuation or reordered handoff events")
    }
}
