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
    public let revision: Int

    init(id: UUID, content: AgentCardRequest, expiresAt: TimeInterval, revision: Int = 0) {
        self.id = id; self.content = content; self.expiresAt = expiresAt; self.revision = revision
    }

    /// The compositor may move a card away from the camera inset without replacing its content.
    public func positioned(_ position: AgentCardPosition) -> AgentCard {
        var content = content
        content.position = position
        return AgentCard(id: id, content: content, expiresAt: expiresAt, revision: revision)
    }
}

public struct AgentTimerRequest: Equatable, Sendable {
    public let durationSeconds: Int
    public let label: String

    public init?(durationSeconds: Int, label: String = "Timer") {
        guard (1...3_600).contains(durationSeconds), label.utf8.count <= 80,
              AgentPresentationState.valid(.init(title: label, body: "0:00")) else { return nil }
        self.durationSeconds = durationSeconds; self.label = label
    }
}

/// Small immutable presentation values; the video path never waits for a tool or disk operation.
public final class AgentPresentationState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [AgentCard] = []
    private var inset: AgentCameraInset?
    private var timer: Countdown?

    private struct Countdown {
        let id = UUID()
        let request: AgentTimerRequest
        let startedAt: TimeInterval
        var endsAt: TimeInterval { startedAt + Double(request.durationSeconds) }
        var expiresAt: TimeInterval { endsAt + 5 }

        func card(at now: TimeInterval) -> AgentCard? {
            guard now >= startedAt, now < expiresAt else { return nil }
            let remaining = Int(ceil(max(0, endsAt - now)))
            let body = remaining == 0 ? "Time’s up" : String(format: "%d:%02d", remaining / 60, remaining % 60)
            // Timer duration has its own one-hour limit; ordinary cards retain their five-minute TTL.
            let content = AgentCardRequest(title: request.label, body: body, style: .metric,
                                           ttlSeconds: Double(request.durationSeconds) + 5)
            return AgentCard(id: id, content: content, expiresAt: expiresAt, revision: remaining)
        }
    }
    public init() {}

    @discardableResult
    public func show(_ request: AgentCardRequest, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> AgentCard? {
        guard now.isFinite, Self.valid(request) else { return nil }
        let card = AgentCard(id: UUID(), content: request, expiresAt: now + request.ttlSeconds)
        lock.lock(); defer { lock.unlock() }
        // One readable card at a time. Saving notes is independent of this transient slot.
        current = [card]
        timer = nil
        return card
    }

    @discardableResult
    public func startTimer(_ request: AgentTimerRequest,
                           at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> AgentCard? {
        guard now.isFinite, now >= 0 else { return nil }
        let value = Countdown(request: request, startedAt: now)
        guard value.endsAt.isFinite, value.endsAt > now, value.expiresAt.isFinite,
              value.expiresAt > value.endsAt, let card = value.card(at: now) else { return nil }
        lock.lock(); defer { lock.unlock() }
        current.removeAll()
        timer = value
        return card
    }

    public func cards(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [AgentCard] {
        guard now.isFinite else { return [] }
        lock.lock(); defer { lock.unlock() }
        if let timer { return timer.card(at: now).map { [$0] } ?? [] }
        return current.filter { $0.expiresAt > now }
    }

    public func clear() { lock.lock(); current.removeAll(); timer = nil; lock.unlock() }

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
    public func reset() { lock.lock(); current.removeAll(); timer = nil; inset = nil; lock.unlock() }

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
