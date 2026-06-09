import XCTest
@testable import CodexProfileCore

final class CodexRPCErrorTests: XCTestCase {

    // MARK: - isAuthRequired: positive cases (one per remaining term)

    func testAuthenticationRequired() {
        XCTAssertTrue(
            CodexRPCError.requestFailed("server says: authentication required").isAuthRequired)
    }

    func testLogIn() {
        XCTAssertTrue(
            CodexRPCError.requestFailed("please log in to continue").isAuthRequired)
    }

    func testLoginRequired() {
        XCTAssertTrue(
            CodexRPCError.requestFailed("login required for this resource").isAuthRequired)
    }

    func testUnauthorized() {
        XCTAssertTrue(
            CodexRPCError.requestFailed("HTTP 401 Unauthorized").isAuthRequired)
    }

    func testTokenExpired() {
        XCTAssertTrue(
            CodexRPCError.requestFailed("your token expired, please refresh").isAuthRequired)
    }

    func testExpiredToken() {
        XCTAssertTrue(
            CodexRPCError.requestFailed("request rejected: expired token").isAuthRequired)
    }

    func testInvalidGrant() {
        XCTAssertTrue(
            CodexRPCError.requestFailed("OAuth error: invalid_grant").isAuthRequired)
    }

    func testRefreshToken() {
        XCTAssertTrue(
            CodexRPCError.requestFailed("failed to exchange refresh token").isAuthRequired)
    }

    // MARK: - isAuthRequired: negative cases (false-positive regressions)

    func testPortNumber4011() {
        XCTAssertFalse(
            CodexRPCError.requestFailed("connection refused (port 4011)").isAuthRequired)
    }

    func testByteCount4030() {
        XCTAssertFalse(
            CodexRPCError.requestFailed("read 4030 bytes").isAuthRequired)
    }

    func testTimeoutMessage4011ms() {
        XCTAssertFalse(
            CodexRPCError.requestFailed("connection timed out after 4011ms").isAuthRequired)
    }

    func testStatus500() {
        XCTAssertFalse(
            CodexRPCError.requestFailed("server returned status 500").isAuthRequired)
    }

    // MARK: - isAuthRequired: non-requestFailed cases always return false

    func testCLINotFoundIsNotAuth() {
        XCTAssertFalse(CodexRPCError.cliNotFound.isAuthRequired)
    }

    func testStartFailedIsNotAuth() {
        XCTAssertFalse(CodexRPCError.startFailed("launch failed").isAuthRequired)
    }

    func testMalformedIsNotAuth() {
        XCTAssertFalse(CodexRPCError.malformed("bad json").isAuthRequired)
    }

    func testTimeoutIsNotAuth() {
        XCTAssertFalse(CodexRPCError.timeout(method: "initialize").isAuthRequired)
    }
}
