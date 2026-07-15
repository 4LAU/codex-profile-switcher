import Combine
import Foundation

enum RefreshInterval: String, CaseIterable, Identifiable {
    case manual
    case oneMinute = "1-minute"
    case twoMinutes = "2-minutes"
    case fiveMinutes = "5-minutes"
    case fifteenMinutes = "15-minutes"

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .manual:
            return "Manual"
        case .oneMinute:
            return "1 minute"
        case .twoMinutes:
            return "2 minutes"
        case .fiveMinutes:
            return "5 minutes"
        case .fifteenMinutes:
            return "15 minutes"
        }
    }

    var timerInterval: TimeInterval? {
        switch self {
        case .manual:
            return nil
        case .oneMinute:
            return 60
        case .twoMinutes:
            return 120
        case .fiveMinutes:
            return 300
        case .fifteenMinutes:
            return 900
        }
    }
}

final class RefreshPreferences: ObservableObject {
    @Published var interval: RefreshInterval {
        didSet {
            self.defaults.set(self.interval.rawValue, forKey: Self.intervalKey)
        }
    }

    @Published var refreshWhenMenuOpens: Bool {
        didSet {
            self.defaults.set(self.refreshWhenMenuOpens, forKey: Self.menuOpenKey)
        }
    }

    private static let intervalKey = "refreshInterval"
    private static let menuOpenKey = "refreshWhenMenuOpens"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.interval = RefreshInterval(
            rawValue: defaults.string(forKey: Self.intervalKey) ?? "") ?? .fiveMinutes
        self.refreshWhenMenuOpens = defaults.bool(forKey: Self.menuOpenKey)
    }
}
