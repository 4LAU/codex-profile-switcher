import Foundation

enum ProfileStoreEnvironmentTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

func envFail(_ message: String) throws -> Never {
    throw ProfileStoreEnvironmentTestFailure.failed(message)
}

func envExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        try envFail(message)
    }
}

func envExpectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        try envFail("\(message) (expected \(expected), got \(actual))")
    }
}

@main
struct ProfileStoreEnvironmentTests {
    static func main() throws {
        try self.run("uses app environment overrides") {
            try self.testUsesAppEnvironmentOverrides()
        }

        print("ProfileStoreEnvironmentTests: all tests passed")
    }

    private static func run(_ name: String, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            fputs("FAIL [\(name)]: \(error)\n", stderr)
            throw error
        }
    }

    private static func testUsesAppEnvironmentOverrides() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-env-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        let authRoot = workDir.appendingPathComponent("auth", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let environment = [
            "CODEX_PROFILE_HOME": home.path,
            "CODEX_PROFILE_KEYCHAIN_SERVICE": "com.example.codex-profile-test",
        ]

        try envExpectEqual(
            ProfileStore.userHome(environment: environment).path,
            home.standardizedFileURL.path,
            "ProfileStore did not resolve CODEX_PROFILE_HOME")
        try envExpectEqual(
            ProfileStore.keychainService(environment: environment),
            "com.example.codex-profile-test",
            "ProfileStore did not resolve CODEX_PROFILE_KEYCHAIN_SERVICE")

        let store = ProfileStore(
            authVault: FileAuthVault(root: authRoot),
            environment: environment)
        let configPath = home.appendingPathComponent(".codex-switcher/config.json").path
        let codexHomePath = home.appendingPathComponent(".codex", isDirectory: true).path

        try envExpect(
            FileManager.default.fileExists(atPath: configPath),
            "ProfileStore did not create config under CODEX_PROFILE_HOME")
        try envExpect(
            store.debugSummaryLines().contains("codex_home: \(codexHomePath)"),
            "Debug summary did not report CODEX_PROFILE_HOME codex path")
    }
}
