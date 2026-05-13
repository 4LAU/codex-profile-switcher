import Foundation

enum RedactorTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

func fail(_ message: String) throws -> Never {
    throw RedactorTestFailure.failed(message)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        try fail(message)
    }
}

func expectRedacted(_ raw: String, removes secrets: [String], keeps markers: [String]) throws {
    let redacted = LogRedactor.redact(raw)
    for secret in secrets {
        try expect(!redacted.contains(secret), "Redacted output still contains secret: \(secret)")
    }
    for marker in markers {
        try expect(redacted.contains(marker), "Redacted output missing marker: \(marker)")
    }
}

@main
struct LogRedactorTests {
    static func main() throws {
        try self.run("redacts emails") {
            try expectRedacted(
                "account user@example.test failed",
                removes: ["user@example.test"],
                keeps: ["<redacted-email>"])
        }
        try self.run("redacts authorization and cookie headers") {
            try expectRedacted(
                """
                Authorization: Bearer access_token_secret_12345
                Cookie: session=secret-session; other=value
                """,
                removes: ["access_token_secret_12345", "session=secret-session"],
                keeps: ["Authorization: <redacted>", "Cookie: <redacted>"])
        }
        try self.run("redacts standalone bearer tokens") {
            try expectRedacted(
                "retrying with Bearer abcdefghijklmnop.qrstuvwxyz-123456",
                removes: ["abcdefghijklmnop.qrstuvwxyz-123456"],
                keeps: ["Bearer <redacted>"])
        }
        try self.run("redacts OpenAI API keys") {
            try expectRedacted(
                "OPENAI_API_KEY=sk-proj_abcdefghijklmnopqrstuvwxyz123456",
                removes: ["sk-proj_abcdefghijklmnopqrstuvwxyz123456"],
                keeps: ["<redacted-openai-key>"])
        }
        try self.run("redacts JSON token fields") {
            try expectRedacted(
                #"{"access_token":"access-secret","refresh_token":"refresh-secret","id_token":"id-secret"}"#,
                removes: ["access-secret", "refresh-secret", "id-secret"],
                keeps: [#""access_token":"<redacted>""#, #""refresh_token":"<redacted>""#, #""id_token":"<redacted>""#])
        }
        try self.run("redacts OAuth query parameters") {
            try expectRedacted(
                "https://example.test/callback?code=secret-code&state=secret-state&access_token=secret-access&id_token=secret-id&safe=1",
                removes: ["secret-code", "secret-state", "secret-access", "secret-id"],
                keeps: ["code=<redacted>", "state=<redacted>", "access_token=<redacted>", "id_token=<redacted>", "safe=1"])
        }
        try self.run("excerpt redacts before truncating") {
            let secret = "user@example.test"
            let excerpt = LogRedactor.excerpt("prefix \(secret)\nAuthorization: Bearer token-secret-123456789", maxLength: 80)
            try expect(!excerpt.contains(secret), "Excerpt leaked email")
            try expect(!excerpt.contains("token-secret-123456789"), "Excerpt leaked bearer token")
            try expect(excerpt.contains("\\n"), "Excerpt should normalize newlines")
        }

        print("LogRedactorTests: all tests passed")
    }

    private static func run(_ name: String, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            fputs("FAIL [\(name)]: \(error)\n", stderr)
            throw error
        }
    }
}
