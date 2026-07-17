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
}
