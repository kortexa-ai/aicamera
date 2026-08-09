import Foundation

public struct WakePhraseMatch: Equatable, Sendable {
    /// Original transcript suffix after the wake phrase, or nil when the phrase was spoken alone.
    public let command: String?
}

public enum WakePhraseDecision: Equatable, Sendable {
    case ignored
    case armed
    case command(String)
}

public struct WakePhraseGate: Equatable, Sendable {
    private var armedUntilUptime: TimeInterval?

    public init() {}

    public mutating func reset() {
        armedUntilUptime = nil
    }

    public mutating func process(
        transcript: String,
        wakePhrase: String,
        windowSeconds: Double,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> WakePhraseDecision {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty, !Self.tokenRanges(in: trimmedTranscript).isEmpty else {
            return .ignored
        }

        if let match = Self.match(transcript: trimmedTranscript, wakePhrase: wakePhrase) {
            if let command = match.command, !command.isEmpty {
                armedUntilUptime = nil
                return .command(command)
            }
            let boundedWindow = min(30, max(1, windowSeconds.isFinite ? windowSeconds : 8))
            armedUntilUptime = uptime + boundedWindow
            return .armed
        }

        guard let armedUntilUptime, uptime <= armedUntilUptime else {
            self.armedUntilUptime = nil
            return .ignored
        }
        self.armedUntilUptime = nil
        return .command(trimmedTranscript)
    }

    static func hasMatchableTokens(_ value: String) -> Bool {
        !tokenRanges(in: value).isEmpty
    }

    public static func match(transcript: String, wakePhrase: String) -> WakePhraseMatch? {
        let transcriptTokens = tokenRanges(in: transcript)
        let phraseTokens = tokenRanges(in: wakePhrase)
        guard !phraseTokens.isEmpty, transcriptTokens.count >= phraseTokens.count else { return nil }

        let transcriptPrefix = transcriptTokens.prefix(phraseTokens.count).map { $0.normalized }
        let phraseValues = phraseTokens.map { $0.normalized }
        guard transcriptPrefix == phraseValues else { return nil }

        let phraseEnd = transcriptTokens[phraseTokens.count - 1].range.upperBound
        var commandStart = phraseEnd
        while commandStart < transcript.endIndex {
            let character = transcript[commandStart]
            guard !character.isLetter, !character.isNumber else { break }
            commandStart = transcript.index(after: commandStart)
        }
        guard commandStart < transcript.endIndex else { return WakePhraseMatch(command: nil) }
        let command = String(transcript[commandStart...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return WakePhraseMatch(command: command.isEmpty ? nil : command)
    }

    private static func tokenRanges(
        in value: String
    ) -> [(normalized: String, range: Range<String.Index>)] {
        let locale = Locale(identifier: "en_US_POSIX")
        var result: [(normalized: String, range: Range<String.Index>)] = []
        var tokenStart: String.Index?
        var index = value.startIndex

        func appendToken(endingAt end: String.Index) {
            guard let start = tokenStart else { return }
            let range = start..<end
            let folded = String(value[range])
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: locale
                )
                .lowercased()
            // Local ASR commonly spells the spoken Kortexa brand name as "Cortexa" or "Cortez".
            let normalized = ["cortexa", "cortez"].contains(folded) ? "kortexa" : folded
            result.append((normalized: normalized, range: range))
            tokenStart = nil
        }

        while index < value.endIndex {
            let character = value[index]
            if character.isLetter || character.isNumber {
                if tokenStart == nil { tokenStart = index }
            } else {
                appendToken(endingAt: index)
            }
            index = value.index(after: index)
        }
        appendToken(endingAt: value.endIndex)
        return result
    }
}
