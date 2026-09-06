import XCTest
@testable import AICameraCore

final class RealtimeSessionPolicyTests: XCTestCase {
    func testLargePCMMessageSplitsWithoutLosingSamplesOrItsTail() throws {
        let data = Data((0..<108_000).map { UInt8($0 % 251) })
        let chunk = RealtimePCMChunk(data: data, sampleRate: 24_000, channels: 1)
        let buffers = try XCTUnwrap(chunk.playbackBuffers)
        XCTAssertEqual(buffers.map(\.count), [48_000, 48_000, 12_000])
        XCTAssertEqual(buffers.reduce(into: Data()) { $0.append($1) }, data)
    }

    func testPCMRejectsMalformedAndOversizedInputBeforePlayback() {
        for chunk in [
            RealtimePCMChunk(data: Data([0]), sampleRate: 24_000, channels: 1),
            RealtimePCMChunk(data: Data(), sampleRate: 24_000, channels: 1),
            RealtimePCMChunk(data: Data([0, 0]), sampleRate: .max, channels: 1),
            RealtimePCMChunk(data: Data([0, 0]), sampleRate: 24_000, channels: 2),
            RealtimePCMChunk(data: Data(count: 256 * 1_024 + 2), sampleRate: 24_000, channels: 1)
        ] {
            XCTAssertNil(chunk.playbackBuffers)
        }
    }

    func testUnarmedAndClosedGatesCannotBeOpenedByServerEvents() {
        var gate = RealtimeTurnGate()
        gate.speechStarted()
        gate.speechStopped(at: 1)
        XCTAssertFalse(gate.isOpen)
        XCTAssertNil(gate.deadline)
        gate.close()
        XCTAssertFalse(gate.arm(at: 2))
        gate.speechStarted()
        XCTAssertEqual(gate.phase, .closed)
    }

    func testNoSpeechExpiresAndRejectsLateRearm() {
        var gate = RealtimeTurnGate()
        XCTAssertTrue(gate.arm(at: 100))
        XCTAssertNil(gate.expire(at: 109.999))
        XCTAssertEqual(gate.expire(at: 110), .noSpeech)
        XCTAssertFalse(gate.isOpen)
        XCTAssertFalse(gate.arm(at: 111))
    }

    func testRepeatedVADCannotExtendTheAbsoluteUtteranceLimit() {
        var gate = RealtimeTurnGate()
        XCTAssertFalse(gate.arm(at: .nan))
        XCTAssertTrue(gate.arm(at: 100))
        gate.speechStarted()
        gate.speechStarted()
        XCTAssertEqual(gate.deadline, 130)
        XCTAssertEqual(gate.expire(at: 130), .utterance)
        gate.speechStarted()
        XCTAssertFalse(gate.isOpen)
    }

    func testVADStopClosesGateAndBoundsAnUnresponsiveServer() {
        var gate = RealtimeTurnGate()
        XCTAssertTrue(gate.arm(at: 0))
        gate.speechStarted()
        gate.speechStopped(at: 3)
        XCTAssertEqual(gate.phase, .responding)
        XCTAssertFalse(gate.isOpen)
        gate.speechStopped(at: 50)
        gate.speechStarted()
        XCTAssertEqual(gate.deadline, 123)
        XCTAssertFalse(gate.arm(at: 50))
        XCTAssertEqual(gate.expire(at: 123), .response)
    }

    func testContinuousConversationWaitsWithoutIdleTimeoutButBoundsActualSpeech() {
        var gate = RealtimeTurnGate()
        XCTAssertTrue(gate.arm(at: 10, continuous: true))
        XCTAssertNil(gate.expire(at: 600))
        XCTAssertTrue(gate.isOpen)
        gate.speechStarted(at: 600)
        gate.speechStarted(at: 610)
        XCTAssertEqual(gate.deadline, 630)
        XCTAssertEqual(gate.expire(at: 630), .utterance)
    }

    func testResponseCompletionKeepsInputClosedUntilPlaybackExplicitlyRearms() {
        var gate = RealtimeTurnGate()
        XCTAssertTrue(gate.arm(at: 1, continuous: true))
        gate.speechStarted(at: 2)
        gate.speechStopped(at: 3)
        XCTAssertFalse(gate.arm(at: 4, continuous: true))
        XCTAssertTrue(gate.responseCompleted())
        XCTAssertFalse(gate.responseCompleted())
        XCTAssertEqual(gate.phase, .awaitingPlayback)
        XCTAssertFalse(gate.isOpen)
        XCTAssertNil(gate.expire(at: 500))
        XCTAssertTrue(gate.arm(at: 501, continuous: true))
        XCTAssertTrue(gate.isOpen)
        gate.close()
        XCTAssertFalse(gate.arm(at: 502, continuous: true))
        XCTAssertFalse(gate.continueResponse(at: 502))
    }

    func testToolContinuationHasItsOwnDeadlineAndCannotOverlapAResponse() {
        var gate = RealtimeTurnGate()
        XCTAssertTrue(gate.continueResponse(at: 1))
        XCTAssertFalse(gate.continueResponse(at: 2))
        XCTAssertTrue(gate.responseCompleted())
        XCTAssertTrue(gate.continueResponse(at: 10))
        XCTAssertEqual(gate.deadline, 130)
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(gate.expire(at: 130), .response)
    }

    func testOrdinaryConversationDeclaresVADAndInputTranscriptionWithoutTools() throws {
        let request = RealtimeSessionConfiguration.request(
            endpoint: endpoint, conversation: .init(), profile: .default, toolsAvailable: false
        )
        let audio = try XCTUnwrap(request["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let vad = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        XCTAssertEqual(vad["type"] as? String, "server_vad")
        XCTAssertEqual(vad["create_response"] as? Bool, true)
        XCTAssertEqual(vad["interrupt_response"] as? Bool, false)
        XCTAssertNotNil(input["transcription"])
        XCTAssertEqual(request["tool_choice"] as? String, "none")
        XCTAssertTrue(try XCTUnwrap(request["tools"] as? [Any]).isEmpty)
        XCTAssertFalse(try XCTUnwrap(request["instructions"] as? String).contains("call render_overlay"))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(request))
    }

    func testAvailableCameraExposesOnlyHostOwnedTools() throws {
        let request = RealtimeSessionConfiguration.request(
            endpoint: endpoint, conversation: .init(), profile: .default, toolsAvailable: true
        )
        let tools = try XCTUnwrap(request["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["render_overlay", "clear_overlay"])
        XCTAssertEqual(request["tool_choice"] as? String, "auto")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(request))
    }

    func testTranscriptDeltasAccumulateAndNewItemsReplaceOldText() {
        var buffer = RealtimeTranscriptBuffer()
        XCTAssertEqual(buffer.update(fragment: "Hello", itemID: "a", isFinal: false), "Hello")
        XCTAssertEqual(buffer.update(fragment: " world", itemID: "a", isFinal: false), "Hello world")
        XCTAssertEqual(buffer.update(fragment: "Hello world.", itemID: "a", isFinal: true), "Hello world.")
        XCTAssertEqual(buffer.update(fragment: "New", itemID: "b", isFinal: false), "New")
        XCTAssertEqual(buffer.update(fragment: "Other", itemID: "c", isFinal: false), "Other")
    }

    func testTranscriptMemoryRemainsBoundedAcrossDeltas() {
        var buffer = RealtimeTranscriptBuffer()
        let fragment = String(repeating: "猫", count: AICameraContentLimits.transcriptCharacters)
        _ = buffer.update(fragment: fragment, itemID: "a", isFinal: false)
        let caption = buffer.update(fragment: fragment, itemID: "a", isFinal: false)
        XCTAssertEqual(caption.count, AICameraContentLimits.transcriptCharacters)
    }

    func testOverlayToolsRejectUnknownFieldsAndNonNumericOrOutOfRangeTTL() {
        let config = ScriptOverlayConfiguration()
        for arguments in [
            #"{"script":"x","ttlSeconds":true}"#,
            #"{"script":"x","ttlSeconds":"30"}"#,
            #"{"script":"x","ttlSeconds":0}"#,
            #"{"script":"x","ttlSeconds":61}"#,
            #"{"script":"x","surprise":1}"#,
            #"{"script":null}"#,
            #"[]"#
        ] {
            XCTAssertNil(RealtimeOverlayCommand.parse(name: "render_overlay", arguments: arguments, configuration: config))
        }
        XCTAssertNil(RealtimeOverlayCommand.parse(name: "unknown", arguments: "{}", configuration: config))
        XCTAssertNil(RealtimeOverlayCommand.parse(name: "clear_overlay", arguments: #"{"x":1}"#, configuration: config))
        XCTAssertEqual(RealtimeOverlayCommand.parse(name: "clear_overlay", arguments: "{}", configuration: config), .clear)
        XCTAssertEqual(RealtimeOverlayCommand.parse(name: "render_overlay", arguments: #"{"script":"x"}"#, configuration: config), .render(script: "x", ttlSeconds: config.defaultTTLSeconds))
    }

    private var endpoint: EndpointConfiguration {
        .init(id: "realtime", adapter: .openAIRealtime, baseURL: URL(string: "https://api.openai.com")!,
              model: "gpt-realtime-2.1", options: ["voice": .string("marin")])
    }
}
