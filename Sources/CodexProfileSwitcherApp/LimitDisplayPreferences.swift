import Combine
import Foundation

enum LimitDisplayMode: String, CaseIterable, Identifiable {
    case used
    case remaining

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .used:
            return "Used"
        case .remaining:
            return "Remaining"
        }
    }

    var settingsDescription: String {
        switch self {
        case .used:
            return "Shows how much of the limit is used: 0% is a full limit, 100% is exhausted."
        case .remaining:
            return "Shows how much of the limit is left: 100% is a full limit, 0% is exhausted."
        }
    }

    /// Reversal lives at the view edge only. Snapshots stay in "used" terms
    /// everywhere else, so selection, exhaustion, and urgency colors keep
    /// keying off the used percent no matter which number the user sees.
    func displayedPercent(forUsedPercent usedPercent: Int) -> Int {
        let normalizedPercent = min(100, max(0, usedPercent))

        switch self {
        case .used:
            return normalizedPercent
        case .remaining:
            return 100 - normalizedPercent
        }
    }
}

@MainActor
final class LimitDisplayPreferences: ObservableObject {
    @Published var mode: LimitDisplayMode {
        didSet {
            self.defaults.set(self.mode.rawValue, forKey: Self.modeKey)
        }
    }

    private static let modeKey = "limitDisplayMode"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mode = LimitDisplayMode(
            rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .used
    }
}
