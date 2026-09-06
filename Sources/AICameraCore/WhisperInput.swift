import Foundation

public enum BuiltinWhisperModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case base
    case small = "small-q5_1"
    case large = "large-v3-q5_0"

    public var id: String { rawValue }
    public var name: String { "Whisper \(sizeName)" }
    public var sizeName: String {
        switch self {
        case .base: "Base"
        case .small: "Small"
        case .large: "Large"
        }
    }
    public var downloadSize: String {
        switch self {
        case .base: "0.148 GB"
        case .small: "0.190 GB"
        case .large: "1.08 GB"
        }
    }
    public var summary: String {
        switch self {
        case .base: "Fastest, with the lowest memory use."
        case .small: "Balances speed and accuracy, with a compact download."
        case .large: "Highest accuracy, with more processing and memory use. Large v3, quantized."
        }
    }

    /// Product eligibility: base M4 and earlier chips keep the two lighter choices.
    /// Unknown hardware fails closed; future chip generations need an explicit policy update.
    public static func availableModels(processorBrand: String) -> [Self] {
        let chip = processorBrand.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let supportsLarge = ["Apple M4 Pro", "Apple M4 Max", "Apple M4 Ultra",
                             "Apple M5", "Apple M5 Pro", "Apple M5 Max", "Apple M5 Ultra"].contains(chip)
        return supportsLarge ? [.base, .small, .large] : [.base, .small]
    }
    public var fileName: String { "ggml-\(rawValue).bin" }
    public var artifact: ModelArtifact {
        let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"
        let bytes: Int64
        let hash: String
        switch self {
        case .base:
            bytes = 147_951_465
            hash = "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
        case .small:
            bytes = 190_085_487
            hash = "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
        case .large:
            bytes = 1_081_140_203
            hash = "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1"
        }
        return .init(
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(revision)/\(fileName)")!,
            sha256: hash, maximumBytes: bytes, expectedBytes: bytes
        )
    }
}

/// The capture pipeline supplies bounded, in-memory 16 kHz mono PCM WAV windows.
public struct WhisperInput: Sendable {
    public let samples: [Float]
    public let isSilent: Bool
    public var duration: Double { Double(samples.count) / 16_000 }

    public enum Failure: LocalizedError {
        case invalidAudio
        public var errorDescription: String? { "Local transcription requires 0.1–30 seconds of 16 kHz mono PCM16 audio." }
    }

    public init(wavData: Data) throws {
        guard wavData.count <= 16_000 * 30 * 2 + 4_096 else { throw Failure.invalidAudio }
        let pcm = try WAVFile.decodePCM16(Data(wavData))
        guard pcm.sampleRate == 16_000, pcm.channels == 1,
              (3_200...960_000).contains(pcm.samples.count), pcm.samples.count % 2 == 0 else { throw Failure.invalidAudio }
        var samples = [Float]()
        samples.reserveCapacity(pcm.samples.count / 2)
        var energy = 0.0
        pcm.samples.withUnsafeBytes { bytes in
            let bytes = bytes.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: bytes.count, by: 2) {
                let integer = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
                let value = Float(integer) / 32_768
                samples.append(value)
                energy += Double(value * value)
            }
        }
        self.samples = samples
        // Only reject near-zero input here; Whisper's no-speech probability handles other silence.
        self.isSilent = energy / Double(samples.count) < 0.000_000_01
    }
}
