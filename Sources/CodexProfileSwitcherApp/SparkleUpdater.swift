import Cocoa

#if canImport(Sparkle)
import Sparkle
#endif

final class SparkleUpdater: NSObject {
    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    func startIfBundledApp() {
        #if canImport(Sparkle)
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self)
        controller.updater.automaticallyChecksForUpdates = true
        self.updaterController = controller
        #endif
    }

    func addMenuItem(to menu: NSMenu) {
        #if canImport(Sparkle)
        guard self.updaterController != nil else { return }
        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(self.checkForUpdates(_:)),
            keyEquivalent: "")
        updateItem.target = self
        updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        updateItem.image?.size = NSSize(width: 13, height: 13)
        menu.addItem(updateItem)
        #endif
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        #if canImport(Sparkle)
        NSApp.activate(ignoringOtherApps: true)
        self.updaterController?.checkForUpdates(sender)
        #endif
    }
}

#if canImport(Sparkle)
extension SparkleUpdater: SPUStandardUserDriverDelegate {
    func standardUserDriverWillShowModalAlert() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard state.userInitiated else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
