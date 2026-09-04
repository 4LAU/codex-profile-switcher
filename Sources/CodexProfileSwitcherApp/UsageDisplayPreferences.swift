import Combine
import Foundation

enum UsageDisplayMode: String, CaseIterable, Identifiable {
    case remaining
    case used

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .remaining: return "Remaining"
        case .used: return "Used"
        }
    }

    func displayPercent(fromUsedPercent usedPercent: Int) -> Int {
        let clamped = min(100, max(0, usedPercent))
        switch self {
        case .remaining: return 100 - clamped
        case .used: return clamped
        }
    }

    func displayText(fromUsedPercent usedPercent: Int) -> String {
        "\(self.displayPercent(fromUsedPercent: usedPercent))% \(self.title.lowercased())"
    }

    func level(forDisplayedPercent percent: Int) -> UsageLevel {
        switch self {
        case .remaining:
            if percent <= 10 { return .critical }
            if percent <= 30 { return .warning }
        case .used:
            if percent >= 90 { return .critical }
            if percent >= 70 { return .warning }
        }
        return .normal
    }
}

enum UsageLevel: Equatable {
    case normal
    case warning
    case critical
}

@MainActor
final class UsageDisplayPreferences: ObservableObject {
    @Published var mode: UsageDisplayMode {
        didSet {
            self.defaults.set(self.mode.rawValue, forKey: Self.modeKey)
        }
    }

    private static let modeKey = "usageDisplayMode"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mode = UsageDisplayMode(
            rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .used
    }
}
