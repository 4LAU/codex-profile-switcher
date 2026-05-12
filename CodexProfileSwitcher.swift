import Cocoa
import SwiftUI

// MARK: - Models

struct ProfileConfig: Codable, Identifiable {
    let id: String
    var label: String
}

struct AppConfig: Codable {
    var profiles: [ProfileConfig]
    var activeProfile: String
}

struct UsageSnapshot: Codable {
    let planType: String?
    let primaryUsedPercent: Int
    let primaryResetAt: Date?
    let secondaryUsedPercent: Int
    let secondaryResetAt: Date?
    let fetchedAt: Date
}

struct UsageCache: Codable {
    var snapshots: [String: UsageSnapshot]
}

enum ProfileStatus {
    case available(UsageSnapshot)
    case loading
    case stale(UsageSnapshot?)
    case reloginNeeded(UsageSnapshot?)
    case notSetUp
}

// MARK: - ProfileStore

final class ProfileStore {
    private let configDir: URL
    private let configURL: URL
    private let cacheURL: URL

    private(set) var config: AppConfig
    private(set) var cache: UsageCache
    var statuses: [String: ProfileStatus] = [:]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.configDir = home.appendingPathComponent(".codex-switcher")
        self.configURL = self.configDir.appendingPathComponent("config.json")
        self.cacheURL = self.configDir.appendingPathComponent("cache.json")

        try? FileManager.default.createDirectory(at: self.configDir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: self.configURL),
           let loaded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self.config = loaded
        } else {
            self.config = AppConfig(profiles: [], activeProfile: "1")
        }

        if let data = try? Data(contentsOf: self.cacheURL),
           let loaded = try? JSONDecoder().decode(UsageCache.self, from: data) {
            self.cache = loaded
        } else {
            self.cache = UsageCache(snapshots: [:])
        }

        if self.config.profiles.isEmpty {
            self.discoverProfiles()
        }

        for profile in self.config.profiles {
            if let cached = self.cache.snapshots[profile.id] {
                self.statuses[profile.id] = .stale(cached)
            } else if self.authFileExists(for: profile.id) {
                self.statuses[profile.id] = .loading
            } else {
                self.statuses[profile.id] = .notSetUp
            }
        }
    }

    func discoverProfiles() {
        var profiles: [ProfileConfig] = []

        for i in 1...8 {
            let id = "\(i)"
            let existing = self.config.profiles.first { $0.id == id }
            profiles.append(ProfileConfig(id: id, label: existing?.label ?? "Profile \(id)"))
        }

        self.config.profiles = profiles
        self.saveConfig()
    }

    func codexHome(for profileId: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex-\(profileId)")
    }

    func authFilePath(for profileId: String) -> URL {
        self.codexHome(for: profileId).appendingPathComponent("auth.json")
    }

    func authFileExists(for profileId: String) -> Bool {
        FileManager.default.fileExists(atPath: self.authFilePath(for: profileId).path)
    }

    func setActiveProfile(_ id: String) {
        self.config.activeProfile = id
        self.saveConfig()
    }

    func updateLabel(for id: String, label: String) {
        if let idx = self.config.profiles.firstIndex(where: { $0.id == id }) {
            self.config.profiles[idx].label = label
            self.saveConfig()
        }
    }

    func updateStatus(_ id: String, _ status: ProfileStatus) {
        self.statuses[id] = status
        if case let .available(snapshot) = status {
            self.cache.snapshots[id] = snapshot
            self.saveCache()
        }
    }

    private func saveConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self.config) else { return }
        try? data.write(to: self.configURL, options: .atomic)
    }

    private func saveCache() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self.cache) else { return }
        try? data.write(to: self.cacheURL, options: .atomic)
    }
}

// MARK: - App Entry Point (placeholder — will be completed in Task 8)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.button?.title = "CPS"
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
