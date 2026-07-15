import Foundation
import Security

public enum KeychainAccessGroupResolver {
    public static let dataProtectionAccessGroup = DataProtectionKeychainAuthVault.accessGroup

    /// Resolves only the single access group this app is entitled to use for
    /// v2 credential storage. Keeping the validation separate from the Security
    /// API makes the safety decision deterministic in hermetic tests.
    public static func resolve(accessGroupsEntitlement: Any?) -> String? {
        guard let accessGroups = accessGroupsEntitlement as? [String],
              accessGroups == [Self.dataProtectionAccessGroup] else {
            return nil
        }
        return Self.dataProtectionAccessGroup
    }

    public static func currentProcessAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let entitlement = SecTaskCopyValueForEntitlement(
                task,
                "keychain-access-groups" as CFString,
                nil) else {
            return nil
        }
        return self.resolve(accessGroupsEntitlement: entitlement)
    }
}
