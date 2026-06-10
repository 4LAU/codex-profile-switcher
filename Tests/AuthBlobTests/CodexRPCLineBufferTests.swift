import XCTest
@testable import CodexProfileCore

final class CodexRPCLineBufferTests: XCTestCase {

    // MARK: - Normal framing

    func testSingleLineDrained() {
        let buf = CodexRPCLineBuffer()
        let input = Data("hello\n".utf8)
        let result = buf.appendAndDrainLines(input)
        XCTAssertFalse(result.overflow)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0], Data("hello".utf8))
    }

    func testMultiLinesDrained() {
        let buf = CodexRPCLineBuffer()
        let input = Data("line1\nline2\nline3\n".utf8)
        let result = buf.appendAndDrainLines(input)
        XCTAssertFalse(result.overflow)
        XCTAssertEqual(result.lines.count, 3)
    }

    func testPartialLineBufferedUntilNewline() {
        let buf = CodexRPCLineBuffer()
        let r1 = buf.appendAndDrainLines(Data("parti".utf8))
        XCTAssertFalse(r1.overflow)
        XCTAssertTrue(r1.lines.isEmpty)

        let r2 = buf.appendAndDrainLines(Data("al\n".utf8))
        XCTAssertFalse(r2.overflow)
        XCTAssertEqual(r2.lines.count, 1)
        XCTAssertEqual(r2.lines[0], Data("partial".utf8))
    }

    func testEmptyLinesSkipped() {
        let buf = CodexRPCLineBuffer()
        let result = buf.appendAndDrainLines(Data("\n\nfoo\n".utf8))
        XCTAssertFalse(result.overflow)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0], Data("foo".utf8))
    }

    // MARK: - 4 MB cap

    func testOversizedSingleLineTriggersOverflow() {
        let buf = CodexRPCLineBuffer()
        // 4 MB + 1 byte of data with no newline → must trigger overflow
        let bigData = Data(repeating: 0x41, count: 4 * 1024 * 1024 + 1)
        let result = buf.appendAndDrainLines(bigData)
        XCTAssertTrue(result.overflow)
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testBufferClearedAfterOverflow() {
        let buf = CodexRPCLineBuffer()
        // Trigger overflow
        let bigData = Data(repeating: 0x41, count: 4 * 1024 * 1024 + 1)
        _ = buf.appendAndDrainLines(bigData)

        // After overflow the buffer should be empty; a normal subsequent write works
        let result = buf.appendAndDrainLines(Data("ok\n".utf8))
        XCTAssertFalse(result.overflow)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0], Data("ok".utf8))
    }

    func testExactlyAtCapDoesNotOverflow() {
        let buf = CodexRPCLineBuffer()
        // Exactly 4 MB without a newline — at the limit, not over
        let atCap = Data(repeating: 0x41, count: 4 * 1024 * 1024)
        let result = buf.appendAndDrainLines(atCap)
        XCTAssertFalse(result.overflow)
        XCTAssertTrue(result.lines.isEmpty)
    }
}
