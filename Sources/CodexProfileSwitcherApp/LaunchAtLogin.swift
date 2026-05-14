import Foundation

enum LaunchAtLogin {
    private static let plistURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/com.codex-profile-switcher.plist")
    }()

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: Self.plistURL.path)
    }

    static func toggle() {
        if Self.isEnabled {
            do {
                try FileManager.default.removeItem(at: Self.plistURL)
                AppLogger.info("Disabled Launch at Login")
            } catch {
                AppLogger.error("Failed to disable Launch at Login", metadata: ["error": error.localizedDescription])
            }
        } else {
            Self.enable()
        }
    }

    private static func enable() {
        let arg0 = ProcessInfo.processInfo.arguments.first ?? ""
        let binaryPath = URL(fileURLWithPath: arg0).resolvingSymlinksInPath().path
        let plistDict: [String: Any] = [
            "Label": "com.codex-profile-switcher",
            "ProgramArguments": [binaryPath],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        let dir = Self.plistURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            try data.write(to: Self.plistURL, options: .atomic)
            AppLogger.info("Enabled Launch at Login")
        } catch {
            AppLogger.error("Failed to enable Launch at Login", metadata: ["error": error.localizedDescription])
        }
    }
}

// MARK: - Entry Point
