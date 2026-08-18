import Foundation

public struct AppPaths {
    public let environment: [String: String]
    private let fileManager: FileManager

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
    }

    public var userHome: URL {
        if let path = self.environment["CODEX_PROFILE_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        if let path = self.environment["CODEX_PROFILE_TEST_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return self.fileManager.homeDirectoryForCurrentUser
    }

    public var switcherHome: URL {
        self.userHome.appendingPathComponent(".codex-switcher", isDirectory: true)
    }

    public var liveCodexHome: URL {
        self.userHome.appendingPathComponent(".codex", isDirectory: true)
    }

    public var configURL: URL {
        self.switcherHome.appendingPathComponent("config.json")
    }

    public var cacheURL: URL {
        self.switcherHome.appendingPathComponent("cache.json")
    }

    /// Advisory `flock` file guarding every read-modify-write of `cacheURL`.
    /// A separate lock file (not the cache itself) so the lock survives the
    /// atomic-rename replacement of the cache and is never itself rewritten.
    public var cacheLockURL: URL {
        self.switcherHome.appendingPathComponent("cache.lock")
    }

    /// Advisory `flock` file guarding auth-vault read-modify-write transactions.
    public var authLockURL: URL {
        self.switcherHome.appendingPathComponent("auth.lock")
    }

    public var legacyAuthDirectory: URL {
        self.switcherHome.appendingPathComponent("auth", isDirectory: true)
    }

    public var liveAuthURL: URL {
        self.liveCodexHome.appendingPathComponent("auth.json")
    }

    public var globalStateURL: URL {
        self.liveCodexHome.appendingPathComponent(".codex-global-state.json")
    }

    public var tempRoot: URL {
        self.switcherHome.appendingPathComponent("tmp", isDirectory: true)
    }

    /// File-based auth vault used by unsigned dev builds, which never touch
    /// the real Keychain (see ProcessSigningIdentity).
    public var devAuthStoreURL: URL {
        self.switcherHome.appendingPathComponent("dev-auth-store", isDirectory: true)
    }
}
