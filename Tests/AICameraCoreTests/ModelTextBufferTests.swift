import XCTest
@testable import AICameraCore

final class ModelTextBufferTests: XCTestCase {
    func testTokenBoundariesMaySplitAnyUnicodeByte() throws {
        let text = "相机 📷 جاهزة e\u{301}"
        var buffer = ModelTextBuffer()
        for byte in text.utf8 { try buffer.append([byte]) }
        XCTAssertEqual(try buffer.finish(), text)
    }

    func testIncompleteOrInvalidUnicodeIsRejected() throws {
        for bytes: [UInt8] in [[0xf0, 0x9f], [0xff], [0xc0, 0x80]] {
            var buffer = ModelTextBuffer()
            try buffer.append(bytes)
            XCTAssertThrowsError(try buffer.finish()) {
                XCTAssertEqual($0 as? ModelTextBuffer.Failure, .invalidUTF8)
            }
        }
    }

    func testByteLimitRejectsTheWholePieceWithoutCorruptingExistingText() throws {
        var buffer = ModelTextBuffer()
        let text = String(repeating: "📷", count: AICameraContentLimits.transcriptCharacters)
        try buffer.append(Array(text.utf8))
        XCTAssertThrowsError(try buffer.append([65])) {
            XCTAssertEqual($0 as? ModelTextBuffer.Failure, .limitExceeded)
        }
        XCTAssertEqual(try buffer.finish(), text)
    }

    func testCharacterLimitDoesNotSilentlyTruncateASCII() throws {
        var buffer = ModelTextBuffer()
        try buffer.append(Array(repeating: 65, count: AICameraContentLimits.transcriptCharacters + 1))
        XCTAssertThrowsError(try buffer.finish()) {
            XCTAssertEqual($0 as? ModelTextBuffer.Failure, .limitExceeded)
        }
    }

    func testEmptyOutputFailsAndWhitespaceIsTrimmed() throws {
        var buffer = ModelTextBuffer()
        try buffer.append(Array(" \n".utf8))
        XCTAssertThrowsError(try buffer.finish())
        try buffer.append(Array("Ready.\n".utf8))
        XCTAssertEqual(try buffer.finish(), "Ready.")
    }
}
