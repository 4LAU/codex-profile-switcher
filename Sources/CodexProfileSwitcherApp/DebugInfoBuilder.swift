import Cocoa
import CodexProfileCore
import CryptoKit
import SwiftUI

// MARK: - Debug Info

enum DebugInfoBuilder {
    static func build(store: ProfileStore) -> String {
        var lines: [String] = [
            "\(AppInfo.name) Debug Info",
            "generated_at: \(ISO8601DateFormatter().string(from: Date()))",
            "app_version: \(AppInfo.version)",
            "macos: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "executable: \(ProcessInfo.processInfo.arguments.first ?? "<unknown>")",
            "helper: \(CodexBridge.helperPathForDebug())",
            "log_file: \(AppLogger.logURL.path)",
            "",
            "State:",
        ]

        lines.append(contentsOf: store.debugSummaryLines().map { "  \($0)" })
        lines.append("")
        lines.append("Recent Logs:")
        lines.append(AppLogger.recentLines(limit: 200))
        return LogRedactor.redact(lines.joined(separator: "\n"))
    }

    static func copyToPasteboard(store: ProfileStore) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.build(store: store), forType: .string)
        AppLogger.info("Copied debug info to pasteboard")
    }

    static func openLogFile() {
        AppLogger.info("Opening log file", metadata: ["path": AppLogger.logURL.path])
        if !FileManager.default.fileExists(atPath: AppLogger.logURL.path) {
            try? FileManager.default.createDirectory(
                at: AppLogger.logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: AppLogger.logURL.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(AppLogger.logURL)
    }

    static func reportBug() {
        AppLogger.info("Opening bug report URL")
        var components = URLComponents(url: AppInfo.issueURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Bug: "),
            URLQueryItem(name: "body", value: """
            ## What happened


            ## Debug info
            Paste the output from Settings > General > Copy Debug Info here.
            """),
        ]
        NSWorkspace.shared.open(components?.url ?? AppInfo.issueURL)
    }
}

// MARK: - App Support
