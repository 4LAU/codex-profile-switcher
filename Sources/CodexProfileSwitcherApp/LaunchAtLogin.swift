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

    private struct LegacyPlistQuarantine {
        let url: URL
        let validatedData: Data
    }

    private static let legacyPlistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.codex-profile-switcher.plist")

    static var state: State {
        guard Self.isEligible else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return Self.validLegacyPlistData() == nil ? .disabled : .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

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

        let validatedLegacyData = try Self.validatedLegacyDataForDisable()
        let quarantine = try Self.quarantineLegacyPlist(validatedData: validatedLegacyData)

        if SMAppService.mainApp.status != .notRegistered {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                if let quarantine {
                    Self.restoreQuarantine(quarantine)
                }
                throw OperationError.failed(error.localizedDescription)
            }
        }

        guard SMAppService.mainApp.status == .notRegistered else {
            if let quarantine {
                Self.restoreQuarantine(quarantine)
            }
            throw OperationError.failed("Launch at Login remained enabled after the disable request.")
        }

        try Self.removeQuarantinedLegacyPlist(quarantine)
    }

    static func migrateLegacyLaunchAgentIfNeeded() {
        guard Self.isEligible,
              FileManager.default.fileExists(atPath: Self.legacyPlistURL.path) else { return }

        guard let validatedData = Self.validLegacyPlistData() else {
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
            guard let quarantineURL = Self.makeQuarantineURL() else {
                AppLogger.warning("Could not allocate a legacy LaunchAgent quarantine path",
                                  metadata: ["path": Self.legacyPlistURL.path])
                return
            }
            do {
                try FileManager.default.moveItem(at: Self.legacyPlistURL, to: quarantineURL)
            } catch {
                AppLogger.warning("Failed to quarantine legacy LaunchAgent plist",
                                  metadata: ["error": error.localizedDescription])
                return
            }
            let quarantine = LegacyPlistQuarantine(url: quarantineURL, validatedData: validatedData)

            guard let quarantinedData = try? Data(contentsOf: quarantineURL),
                  quarantinedData == validatedData,
                  SMAppService.mainApp.status == .enabled else {
                Self.restoreQuarantine(quarantine)
                return
            }

            do {
                try FileManager.default.removeItem(at: quarantineURL)
                AppLogger.info("Migrated legacy LaunchAgent to native Launch at Login")
            } catch {
                AppLogger.warning("Failed to remove quarantined legacy LaunchAgent plist",
                                  metadata: ["error": error.localizedDescription,
                                             "path": quarantineURL.path])
            }
        case .requiresApproval:
            AppLogger.info("Native Launch at Login requires approval; retaining legacy LaunchAgent")
        default:
            AppLogger.warning("Native Launch at Login is not enabled; retaining legacy LaunchAgent")
        }
    }

    private static var isEligible: Bool {
        guard ProcessSigningIdentity.hasDataProtectionKeychainAccess else { return false }
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let installedURL = StartupIdentityGate.installedBundleURL.standardizedFileURL
        return bundleURL == installedURL && Self.canonicalURL(bundleURL) == bundleURL
    }

    private static func validLegacyPlistData() -> Data? {
        guard let data = try? Data(contentsOf: Self.legacyPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              dictionary["Label"] as? String == "com.codex-profile-switcher",
              let arguments = dictionary["ProgramArguments"] as? [Any],
              arguments.count == 1,
              let argument = arguments.first as? String,
              !argument.isEmpty else {
            return nil
        }
        return data
    }

    private static func validatedLegacyDataForDisable() throws -> Data? {
        guard FileManager.default.fileExists(atPath: Self.legacyPlistURL.path) else { return nil }
        guard let data = Self.validLegacyPlistData() else {
            throw OperationError.failed(
                "The legacy Launch at Login item is malformed or not owned by this app; it was left untouched.")
        }
        return data
    }

    private static func quarantineLegacyPlist(validatedData: Data?) throws -> LegacyPlistQuarantine? {
        guard let validatedData else { return nil }
        guard let quarantineURL = Self.makeQuarantineURL() else {
            throw OperationError.failed("Could not prepare the legacy Launch at Login item for disabling.")
        }

        do {
            try FileManager.default.moveItem(at: Self.legacyPlistURL, to: quarantineURL)
        } catch {
            throw OperationError.failed(error.localizedDescription)
        }

        guard let quarantinedData = try? Data(contentsOf: quarantineURL),
              quarantinedData == validatedData else {
            Self.restoreQuarantine(LegacyPlistQuarantine(url: quarantineURL, validatedData: validatedData))
            throw OperationError.failed(
                "The legacy Launch at Login item changed while it was being checked; it was left untouched.")
        }
        return LegacyPlistQuarantine(url: quarantineURL, validatedData: validatedData)
    }

    private static func removeQuarantinedLegacyPlist(_ quarantine: LegacyPlistQuarantine?) throws {
        guard let quarantine else { return }
        guard !FileManager.default.fileExists(atPath: Self.legacyPlistURL.path) else {
            Self.restoreQuarantine(quarantine)
            throw OperationError.failed(
                "The legacy Launch at Login item changed while it was being disabled; it was left untouched.")
        }
        guard let data = try? Data(contentsOf: quarantine.url), data == quarantine.validatedData else {
            Self.restoreQuarantine(quarantine)
            throw OperationError.failed(
                "The legacy Launch at Login item changed while it was being disabled; it was left untouched.")
        }

        do {
            try FileManager.default.removeItem(at: quarantine.url)
        } catch {
            Self.restoreQuarantine(quarantine)
            throw OperationError.failed(
                "The legacy Launch at Login item could not be removed; it was left enabled.")
        }
    }

    private static func makeQuarantineURL() -> URL? {
        let directory = Self.legacyPlistURL.deletingLastPathComponent()
        for _ in 0..<3 {
            let name = ".com.codex-profile-switcher.migration-\(UUID().uuidString).plist"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func restoreQuarantine(_ quarantine: LegacyPlistQuarantine) {
        guard !FileManager.default.fileExists(atPath: Self.legacyPlistURL.path) else {
            AppLogger.warning("Legacy LaunchAgent changed during migration; retaining both files",
                              metadata: ["path": Self.legacyPlistURL.path,
                                         "quarantine": quarantine.url.path])
            return
        }

        guard let data = try? Data(contentsOf: quarantine.url), data == quarantine.validatedData else {
            Self.restoreValidatedLegacyData(quarantine)
            return
        }

        do {
            try FileManager.default.moveItem(at: quarantine.url, to: Self.legacyPlistURL)
            AppLogger.warning("Legacy LaunchAgent was not unchanged; restored it",
                              metadata: ["path": Self.legacyPlistURL.path])
        } catch {
            AppLogger.warning("Legacy LaunchAgent was not unchanged; retaining quarantine",
                              metadata: ["error": error.localizedDescription,
                                         "quarantine": quarantine.url.path])
        }
    }

    private static func restoreValidatedLegacyData(_ quarantine: LegacyPlistQuarantine) {
        do {
            try quarantine.validatedData.write(to: Self.legacyPlistURL, options: .withoutOverwriting)
            AppLogger.warning("Legacy LaunchAgent quarantine changed; restored the validated data",
                              metadata: ["path": Self.legacyPlistURL.path,
                                         "quarantine": quarantine.url.path])
        } catch {
            AppLogger.warning("Legacy LaunchAgent quarantine changed; retaining it",
                              metadata: ["error": error.localizedDescription,
                                         "quarantine": quarantine.url.path])
        }
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

enum RenewalAgent {
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
                return "Credential renewal scheduling is unavailable for this app build."
            case .failed(let message):
                return message
            }
        }
    }

    private static let plistName = "com.4lau.codex-profile-switcher.renew.plist"

    static var state: State {
        guard Self.isEligible else { return .unavailable }
        switch SMAppService.agent(plistName: Self.plistName).status {
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

    static func register() throws {
        guard Self.isEligible else { throw OperationError.unavailable }
        let service = SMAppService.agent(plistName: Self.plistName)
        guard service.status == .notRegistered else { return }
        do {
            try service.register()
        } catch {
            throw OperationError.failed(error.localizedDescription)
        }
    }

    private static var isEligible: Bool {
        guard ProcessSigningIdentity.hasDataProtectionKeychainAccess else { return false }
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let installedURL = StartupIdentityGate.installedBundleURL.standardizedFileURL
        return bundleURL == installedURL && Self.canonicalURL(bundleURL) == bundleURL
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
