import Foundation

enum CLIUsageFetcherTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

func fail(_ message: String) throws -> Never {
    throw CLIUsageFetcherTestFailure.failed(message)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        try fail(message)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        try fail("\(message) (expected \(expected), got \(actual))")
    }
}

@main
struct CLIUsageFetcherTests {
    static func main() async throws {
        try await self.run("fetches usage through isolated Codex RPC home") {
            try await self.testFetchesUsageThroughIsolatedCodexRPCHome()
        }

        print("CLIUsageFetcherTests: all tests passed")
    }

    private static func run(_ name: String, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            fputs("FAIL [\(name)]: \(error)\n", stderr)
            throw error
        }
    }

    private static func testFetchesUsageThroughIsolatedCodexRPCHome() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-cli-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let fakeCodex = workDir.appendingPathComponent("codex")
        let homeLog = workDir.appendingPathComponent("codex-home.txt")
        let authCopy = workDir.appendingPathComponent("auth-copy.json")
        let configCopy = workDir.appendingPathComponent("config-copy.toml")
        let configURL = workDir.appendingPathComponent("config.toml")
        try Data("model = \"gpt-5\"\n".utf8).write(to: configURL)

        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        printf "%s" "${CODEX_HOME:?}" > "\(homeLog.path)"
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              printf '{"id":1,"result":{}}\\n'
              ;;
            *account*rateLimits*read*)
              cp "$CODEX_HOME/auth.json" "\(authCopy.path)"
              cp "$CODEX_HOME/config.toml" "\(configCopy.path)"
              printf '{"id":2,"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":42.4,"resetsAt":1778690000},"secondary":{"usedPercent":7.6,"resetsAt":1779290000},"credits":{"hasCredits":true,"unlimited":false,"balance":"1,234.5"}}}}\\n'
              exit 0
              ;;
          esac
        done
        """
        try Data(script.utf8).write(to: fakeCodex)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodex.path)

        let authData = Data(#"{"OPENAI_API_KEY":"sk-test-cli-usage-1111111111"}"#.utf8)
        let snapshot = try await CLIUsageFetcher.fetch(
            profileId: "UsageProfile",
            authData: authData,
            codexConfigURL: configURL,
            environment: ["CODEX_CLI": fakeCodex.path, "PATH": "/usr/bin:/bin"])

        try expectEqual(snapshot.planType, "pro", "Wrong plan type")
        try expectEqual(snapshot.primaryUsedPercent, 42, "Wrong primary usage")
        try expectEqual(snapshot.secondaryUsedPercent, 8, "Wrong secondary usage")
        try expectEqual(snapshot.creditsRemaining, 1234.5, "Wrong credits balance")
        try expectEqual(try Data(contentsOf: authCopy), authData, "CLI fallback did not receive selected auth")
        try expectEqual(
            try String(contentsOf: configCopy, encoding: .utf8),
            "model = \"gpt-5\"\n",
            "CLI fallback did not copy Codex config")

        let tempHome = URL(fileURLWithPath: try String(contentsOf: homeLog, encoding: .utf8))
        try expect(!FileManager.default.fileExists(atPath: tempHome.path), "Temporary CODEX_HOME was not cleaned up")
    }
}
