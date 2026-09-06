import Foundation

/// Stores only the latest observation for each modality. A slow result is compared with the
/// previous result from the same modality, not with unrelated faster camera or gesture frames.
public actor SceneState {
    private var snapshot = SceneSnapshot()
    private var detectionFrameID: FrameID?
    private var gestureFrameID: FrameID?
    private var visionFrameID: FrameID?
    private var detectionDate: Date?
    private var gestureDate: Date?
    private var visionDate: Date?
    private var transcriptDate: Date?
    private var agentResponseDate: Date?
    private var transcriptPrivacyGeneration: UInt64 = 0
    private var agentPrivacyGeneration: UInt64 = 0

    public init() {}

    public func current() -> SceneSnapshot { snapshot }

    public func current(privacyGeneration: UInt64) -> SceneSnapshot {
        var visible = snapshot
        if transcriptPrivacyGeneration != privacyGeneration { visible.transcript = nil }
        if agentPrivacyGeneration != privacyGeneration { visible.agentResponse = nil }
        return visible
    }

    public func beginFrame(_ frameID: FrameID, at date: Date = Date()) {
        updateFrameMetadata(frameID, at: date)
    }

    @discardableResult
    public func applyDetections(
        _ detections: [Detection],
        frameID: FrameID,
        at date: Date = Date()
    ) -> Bool {
        guard detectionFrameID == nil || frameID >= detectionFrameID! else { return false }
        detectionFrameID = frameID
        detectionDate = date
        snapshot.detections = detections.prefix(AICameraContentLimits.detections).map { detection in
            var detection = detection
            detection.label = detection.label.aicameraLimited(to: AICameraContentLimits.labelCharacters)
            detection.confidence = detection.confidence.isFinite ? min(1, max(0, detection.confidence)) : 0
            func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
            detection.boundingBox = .init(
                x: unit(detection.boundingBox.x),
                y: unit(detection.boundingBox.y),
                width: unit(detection.boundingBox.width),
                height: unit(detection.boundingBox.height)
            )
            if let depth = detection.depthMeters {
                detection.depthMeters = depth.isFinite ? min(1_000_000, max(-1_000_000, depth)) : nil
            }
            return detection
        }
        updateFrameMetadata(frameID, at: date)
        return true
    }

    @discardableResult
    public func applyGestures(
        _ gestures: [GestureObservation],
        frameID: FrameID,
        at date: Date = Date()
    ) -> Bool {
        guard gestureFrameID == nil || frameID >= gestureFrameID! else { return false }
        gestureFrameID = frameID
        gestureDate = date
        snapshot.gestures = gestures.prefix(AICameraContentLimits.gestures).map { gesture in
            var gesture = gesture
            gesture.confidence = gesture.confidence.isFinite ? min(1, max(0, gesture.confidence)) : 0
            if let location = gesture.location {
                let x = location.x.isFinite ? min(1, max(0, location.x)) : 0
                let y = location.y.isFinite ? min(1, max(0, location.y)) : 0
                gesture.location = .init(x: x, y: y)
            }
            return gesture
        }
        updateFrameMetadata(frameID, at: date)
        return true
    }

    @discardableResult
    public func applyVisionSummary(
        _ summary: String,
        frameID: FrameID,
        at date: Date = Date()
    ) -> Bool {
        guard visionFrameID == nil || frameID >= visionFrameID! else { return false }
        visionFrameID = frameID
        visionDate = date
        snapshot.visionSummary = summary.aicameraLimited(to: AICameraContentLimits.sceneTextCharacters)
        updateFrameMetadata(frameID, at: date)
        return true
    }

    public func applyTranscript(_ event: TranscriptEvent, at date: Date = Date(), privacyGeneration: UInt64 = 0) {
        transcriptPrivacyGeneration = privacyGeneration
        var event = event
        event.text = event.text.aicameraLimited(to: AICameraContentLimits.transcriptCharacters)
        snapshot.transcript = event
        transcriptDate = date
    }

    public func applyAgentResponse(_ response: String?, at date: Date = Date(), privacyGeneration: UInt64 = 0) {
        agentPrivacyGeneration = privacyGeneration
        snapshot.agentResponse = response?.aicameraLimited(to: AICameraContentLimits.agentCharacters)
        agentResponseDate = response == nil ? nil : date
    }

    public func setStatus(_ status: String?) {
        snapshot.status = status?.aicameraLimited(to: AICameraContentLimits.statusCharacters)
    }

    public func clearSpeech() {
        snapshot.transcript = nil
        transcriptDate = nil
        snapshot.agentResponse = nil
        agentResponseDate = nil
    }

    /// Removes independently stale observations. Returns true when the snapshot changed.
    @discardableResult
    public func expireResults(olderThan date: Date) -> Bool {
        var changed = false
        if let detectionDate, detectionDate < date, !snapshot.detections.isEmpty {
            snapshot.detections = []
            self.detectionDate = nil
            changed = true
        }
        if let gestureDate, gestureDate < date, !snapshot.gestures.isEmpty {
            snapshot.gestures = []
            self.gestureDate = nil
            changed = true
        }
        if let visionDate, visionDate < date, snapshot.visionSummary != nil {
            snapshot.visionSummary = nil
            self.visionDate = nil
            changed = true
        }
        if let transcriptDate, transcriptDate < date, snapshot.transcript != nil {
            snapshot.transcript = nil
            self.transcriptDate = nil
            changed = true
        }
        if let agentResponseDate, agentResponseDate < date, snapshot.agentResponse != nil {
            snapshot.agentResponse = nil
            self.agentResponseDate = nil
            changed = true
        }
        return changed
    }

    private func updateFrameMetadata(_ frameID: FrameID, at date: Date) {
        if snapshot.frameID == nil || snapshot.frameID! <= frameID {
            snapshot.frameID = frameID
            snapshot.capturedAt = date
        }
    }
}
