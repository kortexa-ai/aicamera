import XCTest
@testable import AICameraCore

final class WAVFileTests: XCTestCase {
    func testPCM16RoundTrip() throws {
        let pcm = Data([0, 0, 255, 127, 0, 128, 4, 0])
        let wav = WAVFile.encodePCM16(samples: pcm, sampleRate: 16_000, channels: 1)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(try WAVFile.pcm16Samples(from: wav), pcm)
        let decoded = try WAVFile.decodePCM16(wav)
        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertEqual(decoded.channels, 1)
    }

    func testRejectsInvalidWAV() {
        XCTAssertThrowsError(try WAVFile.pcm16Samples(from: Data("frog".utf8))) { error in
            XCTAssertEqual(error as? WAVFileError, .invalidHeader)
        }
    }
}
