import XCTest
@testable import AICameraCore

final class WakePhraseGateTests: XCTestCase {
    func testMatchesCasePunctuationAndDiacriticsAtWordBoundaries() {
        XCTAssertEqual(
            WakePhraseGate.match(transcript: "…HEY, Kórtexa! Tell me a joke.", wakePhrase: "hey kortexa"),
            WakePhraseMatch(command: "Tell me a joke.")
        )
        XCTAssertNil(WakePhraseGate.match(transcript: "hey kortexan", wakePhrase: "hey kortexa"))
        XCTAssertNil(WakePhraseGate.match(transcript: "they kortexa", wakePhrase: "hey kortexa"))
        XCTAssertNil(WakePhraseGate.match(transcript: "I heard someone say hey kortexa", wakePhrase: "hey kortexa"))
        XCTAssertEqual(
            WakePhraseGate.match(transcript: "Hey, Cortexa. Local audio works.", wakePhrase: "Hey Kortexa"),
            WakePhraseMatch(command: "Local audio works.")
        )
        XCTAssertEqual(
            WakePhraseGate.match(transcript: "Hey Cortez, tell me a short joke.", wakePhrase: "Hey Kortexa"),
            WakePhraseMatch(command: "tell me a short joke.")
        )
        XCTAssertEqual(
            WakePhraseGate.match(transcript: "Hey Kortexa — Open NASA.gov, please!", wakePhrase: "hey kortexa"),
            WakePhraseMatch(command: "Open NASA.gov, please!")
        )
    }

    func testPhraseAndCommandTriggersImmediately() {
        var gate = WakePhraseGate()
        XCTAssertEqual(
            gate.process(
                transcript: "Hey Kortexa, what is in front of me?",
                wakePhrase: "Hey Kortexa",
                windowSeconds: 8,
                uptime: 100
            ),
            .command("what is in front of me?")
        )
    }

    func testPhraseAloneArmsOneFollowingUtterance() {
        var gate = WakePhraseGate()
        let now: TimeInterval = 100
        XCTAssertEqual(
            gate.process(transcript: "Hey Kortexa", wakePhrase: "Hey Kortexa", windowSeconds: 8, uptime: now),
            .armed
        )
        XCTAssertEqual(
            gate.process(transcript: "!!!", wakePhrase: "Hey Kortexa", windowSeconds: 8, uptime: now + 6),
            .ignored
        )
        XCTAssertEqual(
            gate.process(transcript: "Please summarize this", wakePhrase: "Hey Kortexa", windowSeconds: 8, uptime: now + 7),
            .command("Please summarize this")
        )
        XCTAssertEqual(
            gate.process(transcript: "This should be ignored", wakePhrase: "Hey Kortexa", windowSeconds: 8, uptime: now + 7.5),
            .ignored
        )
    }

    func testArmedWindowExpiresAndIsBounded() {
        var gate = WakePhraseGate()
        let now: TimeInterval = 100
        XCTAssertEqual(
            gate.process(transcript: "Hey Kortexa", wakePhrase: "Hey Kortexa", windowSeconds: 5, uptime: now),
            .armed
        )
        XCTAssertEqual(
            gate.process(transcript: "Too late", wakePhrase: "Hey Kortexa", windowSeconds: 5, uptime: now + 6),
            .ignored
        )
    }
}
