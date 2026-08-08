import Foundation

public enum WAVFileError: LocalizedError, Equatable {
    case invalidHeader
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .invalidHeader: return "Invalid WAV header."
        case .unsupportedFormat: return "Only uncompressed 16-bit PCM WAV audio is supported."
        }
    }
}

public struct PCM16Audio: Equatable, Sendable {
    public var samples: Data
    public var sampleRate: Int
    public var channels: Int

    public init(samples: Data, sampleRate: Int, channels: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public enum WAVFile {
    public static func encodePCM16(samples: Data, sampleRate: Int, channels: Int) -> Data {
        let bytesPerSample = 2
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample
        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36 + samples.count))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(channels))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(byteRate))
        data.appendLittleEndian(UInt16(blockAlign))
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(UInt32(samples.count))
        data.append(samples)
        return data
    }

    public static func decodePCM16(_ wav: Data) throws -> PCM16Audio {
        guard wav.count >= 44,
              String(data: wav[0..<4], encoding: .ascii) == "RIFF",
              String(data: wav[8..<12], encoding: .ascii) == "WAVE" else {
            throw WAVFileError.invalidHeader
        }
        var offset = 12
        var sampleRate: Int?
        var channels: Int?
        var isPCM16 = false
        var sampleData: Data?
        while offset + 8 <= wav.count {
            let id = String(data: wav[offset..<(offset + 4)], encoding: .ascii)
            let size = Int(wav.littleEndianUInt32(at: offset + 4))
            let start = offset + 8
            guard size >= 0, start + size <= wav.count else { throw WAVFileError.invalidHeader }
            if id == "fmt " {
                guard size >= 16 else { throw WAVFileError.invalidHeader }
                isPCM16 = wav.littleEndianUInt16(at: start) == 1 && wav.littleEndianUInt16(at: start + 14) == 16
                channels = Int(wav.littleEndianUInt16(at: start + 2))
                sampleRate = Int(wav.littleEndianUInt32(at: start + 4))
            } else if id == "data" {
                sampleData = Data(wav[start..<(start + size)])
            }
            offset = start + size + (size % 2)
        }
        guard isPCM16,
              let sampleRate, sampleRate > 0,
              let channels, channels > 0,
              let sampleData else {
            throw isPCM16 ? WAVFileError.invalidHeader : WAVFileError.unsupportedFormat
        }
        return PCM16Audio(samples: sampleData, sampleRate: sampleRate, channels: channels)
    }

    public static func pcm16Samples(from wav: Data) throws -> Data {
        try decodePCM16(wav).samples
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) { append(string.data(using: .ascii)!) }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) |
        (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}
