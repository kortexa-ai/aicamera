import Foundation

public enum AICameraContentLimits {
    public static let detections = 128
    public static let gestures = 4
    public static let labelCharacters = 128
    public static let transcriptCharacters = 8_192
    public static let sceneTextCharacters = 8_192
    public static let agentCharacters = 8_192
    public static let promptCharacters = 16_384
    public static let statusCharacters = 512
}

public extension String {
    func aicameraLimited(to maximumCharacters: Int) -> String {
        guard count > maximumCharacters else { return self }
        return String(prefix(maximumCharacters))
    }
}

public struct FrameID: RawRepresentable, Codable, Equatable, Hashable, Comparable, Sendable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct Detection: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var classID: Int?
    public var confidence: Double
    public var boundingBox: NormalizedRect
    public var depthMeters: Double?

    public init(
        id: UUID = UUID(),
        label: String,
        classID: Int? = nil,
        confidence: Double,
        boundingBox: NormalizedRect,
        depthMeters: Double? = nil
    ) {
        self.id = id
        self.label = label
        self.classID = classID
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.depthMeters = depthMeters
    }
}

public enum GestureKind: String, Codable, CaseIterable, Sendable {
    case openPalm
    case closedFist
    case pointing
    case pinch
    case victory
    case unknown
}

public struct GestureObservation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: GestureKind
    public var confidence: Double
    public var location: NormalizedPoint?

    public init(id: UUID = UUID(), kind: GestureKind, confidence: Double, location: NormalizedPoint? = nil) {
        self.id = id; self.kind = kind; self.confidence = confidence; self.location = location
    }
}

public struct TranscriptEvent: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case partial, final }
    public var text: String
    public var mode: Mode
    public var startSeconds: Double?
    public var endSeconds: Double?

    public init(text: String, mode: Mode = .final, startSeconds: Double? = nil, endSeconds: Double? = nil) {
        self.text = text; self.mode = mode; self.startSeconds = startSeconds; self.endSeconds = endSeconds
    }
}

public struct SceneSnapshot: Codable, Equatable, Sendable {
    public var frameID: FrameID?
    public var capturedAt: Date
    public var detections: [Detection]
    public var gestures: [GestureObservation]
    public var visionSummary: String?
    public var transcript: TranscriptEvent?
    public var agentResponse: String?
    public var status: String?

    public init(
        frameID: FrameID? = nil,
        capturedAt: Date = Date(),
        detections: [Detection] = [],
        gestures: [GestureObservation] = [],
        visionSummary: String? = nil,
        transcript: TranscriptEvent? = nil,
        agentResponse: String? = nil,
        status: String? = nil
    ) {
        self.frameID = frameID
        self.capturedAt = capturedAt
        self.detections = detections
        self.gestures = gestures
        self.visionSummary = visionSummary
        self.transcript = transcript
        self.agentResponse = agentResponse
        self.status = status
    }

    public var promptDescription: String {
        var lines: [String] = []
        if !detections.isEmpty {
            lines.append("Objects: " + detections.map { "\($0.label) (\(Int($0.confidence * 100))%)" }.joined(separator: ", "))
        }
        if !gestures.isEmpty {
            lines.append("Gestures: " + gestures.map(\.kind.rawValue).joined(separator: ", "))
        }
        if let visionSummary, !visionSummary.isEmpty { lines.append("Visual summary: \(visionSummary)") }
        return lines.isEmpty ? "No current scene observations." : lines.joined(separator: "\n")
    }
}
