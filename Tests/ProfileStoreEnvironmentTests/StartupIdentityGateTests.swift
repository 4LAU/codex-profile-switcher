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
    func installedProductionBuildWithRealHomeOverrideKeepsProductionIdentity() throws {
        let result = StartupIdentityGate.classify(
            bundleURL: self.installedBundle,
            environment: ["CODEX_PROFILE_HOME": self.realHome.path],
            realHome: self.realHome,
            hasDataProtectionKeychainAccess: true)

        try envExpect(result == .production,
                      "The installed entitled app must keep production identity when its override is the real home")
    }

    @Test
    func isolatedIdentityPinsFileVaultAndDelegatedHelperToIsolatedHome() throws {
        let isolatedHome = URL(fileURLWithPath: "/tmp/codex-profile-isolated")
        let environment = ["CODEX_PROFILE_HOME": isolatedHome.path]
        let decision = StartupIdentityGate.classify(
            bundleURL: self.installedBundle,
            environment: environment,
            realHome: self.realHome,
            hasDataProtectionKeychainAccess: true)

        try envExpect(decision == .isolated,
                      "A distinct profile home must remain isolated even for an entitled installed app")
        let vault = StartupIdentityGate.makeIsolatedAuthVault(environment: environment)
        try envExpect(vault.diagnostics().activeBackend == .file,
                      "An isolated startup selected a non-file auth vault")
        let expectedRoot = isolatedHome.appendingPathComponent(
            ".codex-switcher/dev-auth-store", isDirectory: true)
        try envExpect(vault.root == expectedRoot,
                      "The isolated auth vault was not rooted under the isolated home")

        let helperEnvironment = CodexBridge.helperAuthEnvironment(for: environment)
        try envExpect(
            helperEnvironment["CODEX_PROFILE_FILE_AUTH_STORE_DIR"] == expectedRoot.path,
            "The delegated helper was not pinned to the isolated file vault")
        try envExpect(helperEnvironment["CODEX_PROFILE_FORCE_KEYCHAIN"] == nil,
                      "The delegated helper was allowed to select the production Keychain")
    }

    @Test
    func delegatedHelperRemovesConflictingInheritedBackendSelectors() throws {
        let isolatedHome = URL(fileURLWithPath: "/tmp/codex-profile-isolated-conflict")
        let environment = [
            "CODEX_PROFILE_HOME": isolatedHome.path,
            "CODEX_PROFILE_TEST_AUTH_STORE_DIR": "/tmp/wrong-test-vault",
            "CODEX_PROFILE_FILE_AUTH_STORE_DIR": "/tmp/wrong-file-vault",
            "CODEX_PROFILE_FORCE_KEYCHAIN": "1",
        ]
        let childEnvironment = CodexBridge.helperProcessEnvironment(for: environment)
        let expectedRoot = isolatedHome.appendingPathComponent(
            ".codex-switcher/dev-auth-store", isDirectory: true)

        try envExpect(childEnvironment["CODEX_PROFILE_TEST_AUTH_STORE_DIR"] == nil,
                      "The delegated helper inherited a test auth vault override")
        try envExpect(childEnvironment["CODEX_PROFILE_FORCE_KEYCHAIN"] == nil,
                      "The isolated delegated helper inherited forced Keychain mode")
        try envExpect(childEnvironment["CODEX_PROFILE_FILE_AUTH_STORE_DIR"] == expectedRoot.path,
                      "The isolated delegated helper did not receive the authoritative file vault")
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

    @Test @MainActor
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

    @Test @MainActor
    func recoveryCanonicalizesInjectedInstalledCandidate() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("startup-recovery-canonical-" + UUID().uuidString, isDirectory: true)
        let target = root.appendingPathComponent("Applications/CodexProfileSwitcher.app", isDirectory: true)
        let alias = root
            .appendingPathComponent("Applications/temporary", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("CodexProfileSwitcher.app", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)

        var validatedURL: URL?
        var handedOffURL: URL?
        _ = StartupIdentityGate.resolveRecovery(
            decision: .recovery,
            installedBundleURL: alias,
            validateInstalledBundle: { url in
                validatedURL = url
                return true
            },
            handoff: { url, completion in
                handedOffURL = url
                completion(true)
            },
            scheduleTermination: {},
            continueStartup: {})

        let canonicalTarget = target.standardizedFileURL
        try envExpect(validatedURL == canonicalTarget,
                      "Recovery validation received a non-canonical installed URL")
        try envExpect(handedOffURL == canonicalTarget,
                      "Recovery handoff received a non-canonical installed URL")
    }

    @Test @MainActor
    func symlinkedInstalledBundleRequiresRecoveryAndIsNotValidated() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("startup-identity-symlink-" + UUID().uuidString, isDirectory: true)
        let outsideBundle = root.appendingPathComponent("outside/CodexProfileSwitcher.app", isDirectory: true)
        let installedBundle = root.appendingPathComponent("Applications/CodexProfileSwitcher.app", isDirectory: true)
        let realHome = root.appendingPathComponent("home", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: outsideBundle, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: installedBundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: realHome, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: installedBundle.path, withDestinationPath: outsideBundle.path)

        let decision = StartupIdentityGate.classify(
            bundleURL: installedBundle,
            environment: [:],
            realHome: realHome,
            hasDataProtectionKeychainAccess: true,
            installedBundleURL: installedBundle)
        try envExpect(decision == .recovery,
                      "A symlinked installed bundle must not receive production identity")

        var validated = false
        var handedOff = false
        let outcome = StartupIdentityGate.resolveRecovery(
            decision: decision,
            installedBundleURL: installedBundle,
            validateInstalledBundle: { _ in
                validated = true
                return true
            },
            handoff: { _, completion in
                handedOff = true
                completion(true)
            },
            scheduleTermination: {},
            continueStartup: {})

        try envExpect(outcome == .invalidCandidate,
                      "A symlinked installed bundle must be rejected during recovery")
        try envExpect(!validated && !handedOff,
                      "Recovery must reject a symlinked bundle before validation or handoff")
    }

    @Test @MainActor
    func recoveryWaitsForCompletionAndIgnoresDuplicates() throws {
        var complete: StartupIdentityGate.HandoffCompletion?
        var terminationCount = 0
        let outcome = StartupIdentityGate.resolveRecovery(
            decision: .recovery,
            validateInstalledBundle: { _ in true },
            handoff: { _, callback in complete = callback },
            scheduleTermination: { terminationCount += 1 },
            continueStartup: {})

        try envExpect(outcome == .handedOff, "Recovery did not request an asynchronous handoff")
        try envExpect(terminationCount == 0, "Recovery terminated before handoff completion")
        complete?(true)
        complete?(true)
        try envExpect(terminationCount == 1,
                      "Recovery did not schedule exactly one termination after completion")
    }

    @Test @MainActor
    func invalidRecoveryPresentsFailureAndNeverHandoffsOrContinues() throws {
        var events: [String] = []
        let outcome = StartupIdentityGate.resolveRecovery(
            decision: .recovery,
            validateInstalledBundle: { _ in false },
            handoff: { _, _ in events.append("handoff") },
            scheduleTermination: { events.append("terminate") },
            continueStartup: { events.append("continue") },
            presentInvalidCandidate: { events.append("present") })

        try envExpect(outcome == .invalidCandidate, "Invalid recovery candidate was accepted")
        try envExpect(events == ["present", "terminate"],
                      "Invalid recovery reached handoff or continuation")
    }

    @Test @MainActor
    func concurrentHandoffCompletionFinishesOnceOnMainActor() async throws {
        var completion: StartupIdentityGate.HandoffCompletion?
        var presentationCount = 0
        var terminationCount = 0
        var callbacksWereMainActor = true
        var continued = false
        _ = StartupIdentityGate.resolveRecovery(
            decision: .recovery,
            validateInstalledBundle: { _ in true },
            handoff: { _, callback in completion = callback },
            scheduleTermination: {
                terminationCount += 1
                callbacksWereMainActor = callbacksWereMainActor && Thread.isMainThread
            },
            continueStartup: { continued = true },
            presentInvalidCandidate: {
                presentationCount += 1
                callbacksWereMainActor = callbacksWereMainActor && Thread.isMainThread
            })
        guard let completion else { try envFail("Recovery did not expose its handoff completion") }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    await Task.detached {
                        await completion(false)
                    }.value
                }
            }
        }

        try envExpect(presentationCount == 1, "Concurrent failures presented recovery UI more than once")
        try envExpect(terminationCount == 1, "Concurrent failures scheduled termination more than once")
        try envExpect(callbacksWereMainActor, "Recovery UI callbacks escaped the main actor")
        try envExpect(!continued, "Concurrent recovery completion reached ProfileStore continuation")
    }
}
