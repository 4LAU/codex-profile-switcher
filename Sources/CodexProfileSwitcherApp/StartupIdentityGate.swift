import Foundation

enum StartupIdentityGate {
    enum Decision: Equatable {
        case production
        case isolated
        case recovery
    }

    static let installedBundleURL = URL(fileURLWithPath: "/Applications/CodexProfileSwitcher.app")

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
