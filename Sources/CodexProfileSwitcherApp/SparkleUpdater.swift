import Cocoa

#if canImport(Sparkle)
    import Sparkle
#endif

final class SparkleUpdater: NSObject {
    #if canImport(Sparkle)
        private var updaterController: SPUStandardUpdaterController?
        private var immediateInstallHandler: (() -> Void)?
        private(set) var pendingUpdateVersion: String?
    #endif

    var onUpdateReady: (() -> Void)?

    func startIfBundledApp() {
        #if canImport(Sparkle)
            guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
            let controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: self)
            controller.updater.automaticallyChecksForUpdates = true
            controller.updater.automaticallyDownloadsUpdates = true
            self.updaterController = controller
        #endif
    }

    func addMenuItem(to menu: NSMenu) {
        #if canImport(Sparkle)
            guard self.updaterController != nil else { return }

            if let version = self.pendingUpdateVersion {
                let updateItem = NSMenuItem(
                    title: "Update to v\(version) — restart now?",
                    action: #selector(self.installPendingUpdate(_:)),
                    keyEquivalent: "")
                updateItem.target = self
                updateItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
                updateItem.image?.size = NSSize(width: 13, height: 13)
                menu.addItem(updateItem)
            } else {
                let updateItem = NSMenuItem(
                    title: "Check for Updates...",
                    action: #selector(self.checkForUpdates(_:)),
                    keyEquivalent: "")
                updateItem.target = self
                updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
                updateItem.image?.size = NSSize(width: 13, height: 13)
                menu.addItem(updateItem)
            }
        #endif
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        #if canImport(Sparkle)
            NSApp.activate(ignoringOtherApps: true)
            self.updaterController?.checkForUpdates(sender)
        #endif
    }

    @objc private func installPendingUpdate(_ sender: Any?) {
        #if canImport(Sparkle)
            self.immediateInstallHandler?()
        #endif
    }
}

#if canImport(Sparkle)
    extension SparkleUpdater: SPUUpdaterDelegate {
        func updater(
            _ updater: SPUUpdater,
            willInstallUpdateOnQuit item: SUAppcastItem,
            immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
        ) -> Bool {
            self.immediateInstallHandler = immediateInstallHandler
            self.pendingUpdateVersion = item.displayVersionString
            self.onUpdateReady?()
            return true
        }
    }

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
