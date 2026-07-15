public enum ProcessSigningIdentity {
    /// Whether this process has the exact capability required for the v2 Data
    /// Protection Keychain. A Developer ID signature alone is not sufficient.
    public static let hasDataProtectionKeychainAccess =
        KeychainAccessGroupResolver.currentProcessAccessGroup() != nil

    /// Compatibility alias for existing call sites. It reports the v2 Keychain
    /// capability and makes no assertion about legacy ACL stability.
    public static var isStable: Bool {
        self.hasDataProtectionKeychainAccess
    }
}
