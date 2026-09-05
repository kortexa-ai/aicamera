import Foundation

/// Token pieces are bytes and can split a Unicode scalar. Decode only completed output.
public struct ModelTextBuffer: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case limitExceeded, invalidUTF8, emptyOutput

        public var errorDescription: String? {
            switch self {
            case .limitExceeded: "The local model output exceeded its text limit."
            case .invalidUTF8: "The local model returned incomplete or invalid text."
            case .emptyOutput: "The local model returned no text."
            }
        }
    }

    public static let maximumBytes = AICameraContentLimits.transcriptCharacters * 4
    private var bytes = Data()

    public init() {}

    public mutating func append(_ piece: [UInt8]) throws {
        guard piece.count <= Self.maximumBytes - bytes.count else { throw Failure.limitExceeded }
        bytes.append(contentsOf: piece)
    }

    public func finish() throws -> String {
        guard let decoded = String(data: bytes, encoding: .utf8) else { throw Failure.invalidUTF8 }
        let result = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw Failure.emptyOutput }
        guard result.count <= AICameraContentLimits.transcriptCharacters else { throw Failure.limitExceeded }
        return result
    }
}
