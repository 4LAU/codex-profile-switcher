import Cocoa

#if canImport(Sparkle)
import Sparkle
#endif

final class SparkleUpdater {
    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    func startIfBundledApp() {
        #if canImport(Sparkle)
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = true
        controller.startUpdater()
        self.updaterController = controller
        #endif
    }

    func addMenuItem(to menu: NSMenu) {
        #if canImport(Sparkle)
        guard let controller = self.updaterController else { return }
        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: "")
        updateItem.target = controller
        updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        updateItem.image?.size = NSSize(width: 13, height: 13)
        menu.addItem(updateItem)
        #endif
    }
}
