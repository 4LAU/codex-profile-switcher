import Foundation
import Testing
@testable import CodexProfileCore

@Suite(.serialized)
struct TokenRenewalTests {
    @Test
    func renewalPolicyTreatsMissingStaleAndMateriallyFutureDatesAsDueWhenNeeded() {
        let policy = RenewalPolicy()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(policy.isDue(lastRefresh: nil, now: now))
        #expect(!policy.isDue(lastRefresh: now.addingTimeInterval(-60), now: now))
        // A materially future timestamp is invalid persisted state and is due.
        #expect(policy.isDue(lastRefresh: now.addingTimeInterval(10 * 60), now: now))
        #expect(policy.isDue(lastRefresh: now.addingTimeInterval(-4 * 24 * 60 * 60), now: now))
    }

    @Test
    func updatedBlobPreservesUnrelatedFieldsAndStampsRefreshDate() throws {
        let existing = Data(#"{"metadata":{"keep":true},"tokens":{"access_token":"old-access","refresh_token":"old-refresh","account_id":"acct"}}"#.utf8)
        let refreshDate = Date(timeIntervalSince1970: 1_800_000_123.456)
        let credentials = AuthCredentials(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: "new-id",
            accountId: "acct",
            lastRefresh: nil)

        let updated = try AuthBlob.updatedData(from: existing, with: credentials, lastRefresh: refreshDate)
        let json = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let metadata = try #require(json["metadata"] as? [String: Any])
        let tokens = try #require(json["tokens"] as? [String: Any])

        #expect(metadata["keep"] as? Bool == true)
        #expect(tokens["access_token"] as? String == "new-access")
        #expect(tokens["refresh_token"] as? String == "new-refresh")
        #expect(json["last_refresh"] as? String == "2027-01-15T08:02:03.456Z")
    }

    @Test
    func renewalRotatesRefreshTokenAndPreservesItWhenResponseOmitsOne() async throws {
        let existing = AuthCredentials(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            idToken: "old-id",
            accountId: "acct",
            lastRefresh: nil)
        let rotated = try await TokenRenewal.renew(
            credentials: existing,
            using: StubRefresher(response: TokenRefreshResponse(
                accessToken: "new-access", refreshToken: "new-refresh")))
        let unchanged = try await TokenRenewal.renew(
            credentials: existing,
            using: StubRefresher(response: TokenRefreshResponse(accessToken: "new-access")))

        #expect(rotated.refreshToken == "new-refresh")
        #expect(unchanged.refreshToken == "old-refresh")
    }

    @Test
    func omittedIdentityFieldsPreserveFingerprint() async throws {
        let existingData = Data(#"{"tokens":{"access_token":"old-access","refresh_token":"old-refresh","id_token":"old-id","account_id":"acct"}}"#.utf8)
        let existing = try AuthBlob.load(from: existingData)
        let renewed = try await TokenRenewal.renew(
            credentials: existing,
            using: StubRefresher(response: TokenRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh")))
        let updatedData = try AuthBlob.updatedData(from: existingData, with: renewed, lastRefresh: Date())

        #expect(renewed.idToken == existing.idToken)
        #expect(renewed.accountId == existing.accountId)
        #expect(AuthBlob.identityFingerprint(from: updatedData) == AuthBlob.identityFingerprint(from: existingData))
    }

    @Test
    func unauthorizedResponseIsRejected() async {
        let session = URLSession(configuration: Self.protocolSessionConfiguration { request in
            (HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]),
             Data(#"{"error":"invalid_grant"}"#.utf8))
        })

        do {
            _ = try await URLSessionTokenRefresher(session: session).refresh(refreshToken: "refresh")
            Issue.record("401 unexpectedly succeeded")
        } catch let error as TokenRenewalError {
            #expect(error == .rejected("HTTP 401: invalid_grant"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func transportFailureIsUnreachable() async {
        let session = URLSession(configuration: Self.protocolSessionConfiguration { _ in
            throw URLError(.cannotConnectToHost)
        })

        do {
            _ = try await URLSessionTokenRefresher(session: session).refresh(refreshToken: "refresh")
            Issue.record("transport failure unexpectedly succeeded")
        } catch let error as TokenRenewalError {
            if case .unreachable = error {
                return
            } else {
                Issue.record("transport failure was not unreachable: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    private static func protocolSessionConfiguration(
        _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse?, Data)
    ) -> URLSessionConfiguration {
        TestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        return configuration
    }
}

private struct StubRefresher: TokenRefreshing {
    let response: TokenRefreshResponse

    func refresh(refreshToken: String) async throws -> TokenRefreshResponse {
        response
    }
}

private final class TestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse?, Data))!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler(self.request)
            if let response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
