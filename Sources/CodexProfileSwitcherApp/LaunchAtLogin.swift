import Foundation
import CodexProfileCore
import ServiceManagement

enum LaunchAtLogin {
    enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable
    }

    enum OperationError: LocalizedError {
        case unavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Launch at Login is unavailable for this app build."
            case .failed(let message):
                return message
            }
        }
    }

    private static let legacyPlistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.codex-profile-switcher.plist")

    static var state: State {
        guard Self.isEligible else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    // Transitional compatibility for the current settings view; Task 4 removes this surface.
    static var isEnabled: Bool { Self.state == .enabled }

    static func enable() throws {
        guard Self.isEligible else { throw OperationError.unavailable }
        do {
            try SMAppService.mainApp.register()
        } catch {
            throw OperationError.failed(error.localizedDescription)
        }
    }

    static func disable() throws {
        guard Self.isEligible else { throw OperationError.unavailable }
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            throw OperationError.failed(error.localizedDescription)
        }
    }

    // Transitional compatibility for the current settings view; this never writes a plist.
    static func toggle() {
        do {
            if Self.isEnabled {
                try Self.disable()
            } else {
                try Self.enable()
            }
        } catch {
            AppLogger.error("Failed to change Launch at Login", metadata: ["error": error.localizedDescription])
        }
    }

    static func migrateLegacyLaunchAgentIfNeeded() {
        guard Self.isEligible,
              FileManager.default.fileExists(atPath: Self.legacyPlistURL.path) else { return }

        guard Self.validLegacyPlist() else {
            AppLogger.warning("Legacy LaunchAgent plist is malformed or unexpected; leaving it untouched",
                              metadata: ["path": Self.legacyPlistURL.path])
            return
        }

        let service = SMAppService.mainApp
        if service.status != .enabled {
            do {
                try service.register()
            } catch {
                AppLogger.warning("Failed to register native Launch at Login service",
                                  metadata: ["error": error.localizedDescription])
            }
        }

        switch service.status {
        case .enabled:
            do {
                try FileManager.default.removeItem(at: Self.legacyPlistURL)
                AppLogger.info("Migrated legacy LaunchAgent to native Launch at Login")
            } catch {
                AppLogger.warning("Failed to remove legacy LaunchAgent plist",
                                  metadata: ["error": error.localizedDescription])
            }
        case .requiresApproval:
            AppLogger.info("Native Launch at Login requires approval; retaining legacy LaunchAgent")
        default:
            AppLogger.warning("Native Launch at Login is not enabled; retaining legacy LaunchAgent")
        }
    }

    private static var isEligible: Bool {
        guard ProcessSigningIdentity.hasDataProtectionKeychainAccess else { return false }
        return Self.canonicalURL(Bundle.main.bundleURL) == Self.canonicalURL(StartupIdentityGate.installedBundleURL)
    }

    private static func validLegacyPlist() -> Bool {
        guard let data = try? Data(contentsOf: Self.legacyPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              dictionary["Label"] as? String == "com.codex-profile-switcher",
              let arguments = dictionary["ProgramArguments"] as? [Any],
              arguments.count == 1,
              let argument = arguments.first as? String,
              !argument.isEmpty else {
            return false
        }
        return true
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
