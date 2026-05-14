import Foundation

public enum ProfileValidator {
    public static func isValid(_ profile: String) -> Bool {
        profile.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    public static func validate(_ profile: String) throws {
        guard self.isValid(profile) else {
            throw ProfileValidationError.invalidProfile(profile)
        }
    }
}

public enum ProfileValidationError: LocalizedError, Equatable {
    case invalidProfile(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProfile(let profile):
            return "Invalid profile '\(profile)'. Use letters, numbers, dots, dashes, or underscores."
        }
    }
}
