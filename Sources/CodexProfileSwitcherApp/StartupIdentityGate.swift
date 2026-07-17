import Foundation
import Cocoa
import Security

enum StartupIdentityGate {
    typealias HandoffCompletion = @MainActor @Sendable (Bool) -> Void

    enum Decision: Equatable {
        case production
        case isolated
        case recovery
    }

    enum RecoveryOutcome: Equatable {
        case continued
        case handedOff
        case invalidCandidate
    }

    static let installedBundleURL = URL(fileURLWithPath: "/Applications/CodexProfileSwitcher.app")
    static let recoveryLaunchArgument = "--codex-profile-switcher-recovery"
    static let recoveryNoticeName =
        Notification.Name("com.4lau.codex-profile-switcher.startup-repaired")

    private static let expectedBundleIdentifier = "com.4lau.codex-profile-switcher"
    private static let expectedTeamIdentifier = "W3ZHLSH96F"
    private static let expectedKeychainAccessGroup =
        "W3ZHLSH96F.com.4lau.codex-profile-switcher.auth-v2"

    static func classify(
        bundleURL: URL,
        environment: [String: String],
        realHome: URL,
        hasDataProtectionKeychainAccess: Bool,
        installedBundleURL: URL = Self.installedBundleURL
    ) -> Decision {
        let canonicalRealHome = Self.canonicalURL(realHome)
        if let overrideURL = Self.profileHomeOverride(in: environment) {
            return Self.canonicalURL(overrideURL) == canonicalRealHome ? .recovery : .isolated
        }

        guard hasDataProtectionKeychainAccess,
              Self.canonicalURL(bundleURL) == Self.canonicalURL(installedBundleURL) else {
            return .recovery
        }
        return .production
    }

    @MainActor
    static func resolveRecovery(
        decision: Decision,
        installedBundleURL: URL = Self.installedBundleURL,
        validateInstalledBundle: (URL) -> Bool,
        handoff: @MainActor (URL, @escaping HandoffCompletion) -> Void,
        scheduleTermination: @escaping @MainActor () -> Void,
        continueStartup: @escaping @MainActor () -> Void,
        presentInvalidCandidate: @escaping @MainActor () -> Void = {}) -> RecoveryOutcome {
        guard decision == .recovery else {
            continueStartup()
            return .continued
        }

        let candidate = Self.canonicalURL(installedBundleURL)
        guard validateInstalledBundle(candidate) else {
            presentInvalidCandidate()
            scheduleTermination()
            return .invalidCandidate
        }

        var completionHandled = false
        handoff(candidate) { success in
            guard !completionHandled else { return }
            completionHandled = true
            if success {
                AppLogger.info("Startup repair handed off to installed app")
            } else {
                presentInvalidCandidate()
            }
            scheduleTermination()
        }
        return .handedOff
    }

    static func validateInstalledBundle(_ candidate: URL) -> Bool {
        let canonicalCandidate = Self.canonicalURL(candidate)
        guard canonicalCandidate == Self.canonicalURL(Self.installedBundleURL),
              FileManager.default.fileExists(atPath: canonicalCandidate.path) else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(canonicalCandidate as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                  nil) == errSecSuccess else {
            return false
        }

        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo) == errSecSuccess,
            let info = signingInfo as? [String: Any],
            info[kSecCodeInfoIdentifier as String] as? String == Self.expectedBundleIdentifier,
            info[kSecCodeInfoTeamIdentifier as String] as? String == Self.expectedTeamIdentifier,
            let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
            let groups = entitlements["keychain-access-groups"] as? [String] else {
            return false
        }
        return groups.count == 1 && groups[0] == Self.expectedKeychainAccessGroup
    }

    @MainActor
    static func handoffToInstalledApp(
        _ validatedURL: URL,
        completion: @escaping HandoffCompletion) {
        let canonicalInstalledURL = Self.canonicalURL(validatedURL)
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.expectedBundleIdentifier)
            .first { application in
                guard let url = application.bundleURL else { return false }
                return Self.canonicalURL(url) == canonicalInstalledURL
        }
        if let running {
            let activated = Self.activateValidatedRunningInstance(
                runningBundleURL: running.bundleURL,
                validatedURL: canonicalInstalledURL,
                postNotice: Self.postRecoveryNotice,
                activate: { running.activate(options: [.activateAllWindows]) })
            completion(activated)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [Self.recoveryLaunchArgument]
        configuration.activates = true
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(at: validatedURL, configuration: configuration) { application, error in
            Task { @MainActor in
                completion(application != nil && error == nil)
            }
        }
    }

    static func activateValidatedRunningInstance(
        runningBundleURL: URL?,
        validatedURL: URL,
        postNotice: () -> Void,
        activate: () -> Bool) -> Bool {
        guard let runningBundleURL,
              Self.canonicalURL(runningBundleURL) == Self.canonicalURL(validatedURL) else {
            return false
        }
        postNotice()
        return activate()
    }

    static func postRecoveryNotice() {
        DistributedNotificationCenter.default().post(
            name: Self.recoveryNoticeName,
            object: nil,
            userInfo: nil)
    }

    private static func profileHomeOverride(in environment: [String: String]) -> URL? {
        for key in ["CODEX_PROFILE_HOME", "CODEX_PROFILE_TEST_HOME"] {
            if let path = environment[key], !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
