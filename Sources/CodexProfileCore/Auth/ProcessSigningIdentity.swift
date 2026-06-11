import Foundation
import Security

/// Whether the running binary has a stable code-signing identity.
///
/// Keychain item ACLs trust the binary's designated requirement. A binary
/// signed with a team identifier keeps the same designated requirement across
/// rebuilds and releases, so a user's one-time "Always Allow" holds forever.
/// An ad-hoc build (plain `swift build`) has a unique per-build identity, so
/// every rebuild would trigger a macOS consent prompt per saved profile.
/// Callers use this to route unsigned dev builds away from the real Keychain
/// entirely (the CodexBar pattern) instead of churning ACL prompts.
public enum ProcessSigningIdentity {
    public static let isStable: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info) == errSecSuccess,
            let dict = info as? [String: Any] else { return false }
        return dict[kSecCodeInfoTeamIdentifier as String] != nil
    }()
}
