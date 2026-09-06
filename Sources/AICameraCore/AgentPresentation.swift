import Foundation

public enum AgentCardPosition: String, Codable, CaseIterable, Sendable {
    case upperLeft, upperRight, lowerLeft, lowerRight
}

public enum AgentCardStyle: String, Codable, CaseIterable, Sendable { case information, sticky, metric }

public struct AgentCardRequest: Equatable, Sendable {
    public var title: String
    public var body: String
    public var source: String?
    public var style: AgentCardStyle
    public var position: AgentCardPosition
    public var ttlSeconds: Double

    public init(title: String, body: String, source: String? = nil, style: AgentCardStyle = .information,
                position: AgentCardPosition = .lowerLeft, ttlSeconds: Double = 30) {
        self.title = title; self.body = body; self.source = source
        self.style = style; self.position = position; self.ttlSeconds = ttlSeconds
    }
}

public struct AgentCard: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let content: AgentCardRequest
    public let expiresAt: TimeInterval

    /// The compositor may move a card away from the camera inset without replacing its content.
    public func positioned(_ position: AgentCardPosition) -> AgentCard {
        var content = content
        content.position = position
        return AgentCard(id: id, content: content, expiresAt: expiresAt)
    }
}

/// Small immutable presentation values; the video path never waits for a tool or disk operation.
public final class AgentPresentationState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [AgentCard] = []
    private var inset: AgentCameraInset?
    public init() {}

    @discardableResult
    public func show(_ request: AgentCardRequest, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> AgentCard? {
        guard now.isFinite, Self.valid(request) else { return nil }
        let card = AgentCard(id: UUID(), content: request, expiresAt: now + request.ttlSeconds)
        lock.lock(); defer { lock.unlock() }
        // One readable card at a time. Saving notes is independent of this transient slot.
        current = [card]
        return card
    }

    public func cards(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [AgentCard] {
        guard now.isFinite else { return [] }
        lock.lock(); defer { lock.unlock() }
        return current.filter { $0.expiresAt > now }
    }

    public func clear() { lock.lock(); current.removeAll(); lock.unlock() }

    @discardableResult
    public func showCameraInset(_ request: AgentCameraInsetRequest,
                                at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> AgentCameraInset? {
        guard now.isFinite else { return nil }
        let value = AgentCameraInset(id: UUID(), request: request, expiresAt: now + request.ttlSeconds)
        lock.lock(); defer { lock.unlock() }
        inset = value
        return value
    }

    public func cameraInset(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> AgentCameraInset? {
        lock.lock(); defer { lock.unlock() }
        guard now.isFinite, let inset, inset.expiresAt > now else { return nil }
        return inset
    }

    public func cameraLayout(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> AgentCameraLayout {
        lock.lock(); defer { lock.unlock() }
        guard let inset else { return .camera }
        guard now.isFinite, inset.expiresAt > now else { return .expired }
        return .inset(inset.request)
    }

    public func clearCameraInset() { lock.lock(); inset = nil; lock.unlock() }
    public func reset() { lock.lock(); current.removeAll(); inset = nil; lock.unlock() }

    public static func valid(_ value: AgentCardRequest) -> Bool {
        validText(value.title, maximumBytes: 160) && validText(value.body, maximumBytes: 1_200)
            && (value.source.map { validText($0, maximumBytes: 240) } ?? true)
            && value.ttlSeconds.isFinite && (1...300).contains(value.ttlSeconds)
    }

    private static func validText(_ text: String, maximumBytes: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximumBytes
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }
    }
}
