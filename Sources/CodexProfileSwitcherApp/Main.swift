import Cocoa
import CodexProfileCore

#if !TESTING
@main
#endif
enum Main {
    static func main() {
        if let probeStatus = KeychainProbeRunner.runIfRequested() {
            exit(probeStatus)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Hide Codex Profile Switcher",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Codex Profile Switcher",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        let appMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        appMenuItem.submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowMenuItem.submenu = windowMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(fileMenuItem)
        mainMenu.addItem(editMenuItem)
        mainMenu.addItem(windowMenuItem)
        app.mainMenu = mainMenu

        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

private enum KeychainProbeRunner {
    static func runIfRequested() -> Int32? {
        guard let action = ProcessInfo.processInfo.environment["CODEX_PROFILE_KEYCHAIN_PROBE"] else {
            return nil
        }

        do {
            try self.run(action: action)
            return 0
        } catch {
            fputs("Keychain probe failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func run(action: String) throws {
        let env = ProcessInfo.processInfo.environment
        let service = env["CODEX_PROFILE_KEYCHAIN_SERVICE"] ?? LegacyKeychainAuthVault.defaultService
        let profile = env["CODEX_PROFILE_KEYCHAIN_PROBE_PROFILE"] ?? "Probe"
        let marker = env["CODEX_PROFILE_KEYCHAIN_PROBE_MARKER"] ?? "probe"
        let vault = MigratingAuthVault(
            service: service,
            accessGroup: KeychainAccessGroupResolver.configuredAccessGroup(environment: env),
            migrationComplete: true)
        let diagnostics = vault.diagnostics()
        guard diagnostics.activeBackend == .dataProtectionShared else {
            throw ProbeError.backendUnavailable(diagnostics.dataProtectionProbe ?? "<none>")
        }

        switch action {
        case "write":
            try vault.saveAuthBlob(self.authData(marker: marker), profileID: profile)
        case "read":
            guard let data = try vault.loadAuthBlob(profileID: profile),
                  self.marker(in: data) == marker else {
                throw ProbeError.readbackMismatch
            }
        case "delete":
            try vault.deleteAuthBlob(profileID: profile)
        default:
            throw ProbeError.unknownAction(action)
        }
        print("keychain_probe=\(action) backend=\(diagnostics.activeBackend.rawValue)")
    }

    private static func authData(marker: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "OPENAI_API_KEY": "sk-test-keychain-probe-1111111111111111",
                "marker": marker,
            ],
            options: [.prettyPrinted, .sortedKeys])
    }

    private static func marker(in data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["marker"] as? String
    }

    private enum ProbeError: LocalizedError {
        case backendUnavailable(String)
        case readbackMismatch
        case unknownAction(String)

        var errorDescription: String? {
            switch self {
            case .backendUnavailable(let probe):
                return "data protection backend unavailable: \(probe)"
            case .readbackMismatch:
                return "probe item was missing or did not match"
            case .unknownAction(let action):
                return "unknown keychain probe action: \(action)"
            }
        }
    }
}
