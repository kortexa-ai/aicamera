import XCTest
@testable import AICameraCore

final class WhisperInputTests: XCTestCase {
    func testSilenceDoesNotNeedModelInference() throws {
        let input = try WhisperInput(wavData: wav(Data(count: 32_000)))
        XCTAssertTrue(input.isSilent)
        XCTAssertEqual(input.duration, 1)
    }

    func testPCMExtremaRemainFiniteAndPreserveTheirSign() throws {
        var data = Data([0x00, 0x80, 0xff, 0x7f])
        data.append(Data(count: 3_196))
        let input = try WhisperInput(wavData: wav(data))
        XCTAssertEqual(input.samples[0], -1)
        XCTAssertEqual(input.samples[1], Float(Int16.max) / 32_768)
        XCTAssertFalse(input.isSilent)
    }

    func testWrongFormatsAndOversizedWindowsAreRejected() {
        for data in [
            wav(Data(count: 3_200), rate: 48_000),
            wav(Data(count: 6_400), channels: 2),
            wav(Data(count: 3_201)),
            wav(Data(count: 3_198)),
            wav(Data(count: 960_002)),
            Data("not WAV".utf8)
        ] { XCTAssertThrowsError(try WhisperInput(wavData: data)) }
    }

    func testNonzeroDataSliceOffsetsDoNotChangeDecodedSamples() throws {
        let original = wav(Data(count: 3_200))
        var prefixed = Data(repeating: 1, count: 10)
        prefixed.append(original)
        let input = try WhisperInput(wavData: prefixed.dropFirst(10))
        XCTAssertEqual(input.samples.count, 1_600)
        XCTAssertTrue(input.isSilent)
    }

    private func wav(_ samples: Data, rate: Int = 16_000, channels: Int = 1) -> Data {
        WAVFile.encodePCM16(samples: samples, sampleRate: rate, channels: channels)
    }
}
