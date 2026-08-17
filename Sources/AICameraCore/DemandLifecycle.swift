public struct MediaDemandDecision: Equatable, Sendable {
    public let cameraShouldRun: Bool
    public let microphoneShouldRun: Bool

    public init(cameraShouldRun: Bool, microphoneShouldRun: Bool) {
        self.cameraShouldRun = cameraShouldRun
        self.microphoneShouldRun = microphoneShouldRun
    }

    public static func resolve(
        configurationUsable: Bool,
        cameraRequested: Bool,
        cameraAvailable: Bool,
        cameraAuthorized: Bool,
        microphoneRequested: Bool,
        microphoneAvailable: Bool,
        microphoneAuthorized: Bool
    ) -> Self {
        Self(
            cameraShouldRun: configurationUsable
                && cameraRequested && cameraAvailable && cameraAuthorized,
            microphoneShouldRun: configurationUsable
                && microphoneRequested && microphoneAvailable && microphoneAuthorized
        )
    }
}

/// Resolves explicit local tests before normal availability and authorization checks.
/// Any external virtual-device client has priority and cancels both local tests.
public struct MediaTestDemandDecision: Equatable, Sendable {
    public let cameraRequested: Bool
    public let microphoneRequested: Bool
    public let cameraTestActive: Bool
    public let microphoneTestActive: Bool

    public init(
        cameraRequested: Bool,
        microphoneRequested: Bool,
        cameraTestActive: Bool,
        microphoneTestActive: Bool
    ) {
        self.cameraRequested = cameraRequested
        self.microphoneRequested = microphoneRequested
        self.cameraTestActive = cameraTestActive
        self.microphoneTestActive = microphoneTestActive
    }

    public static func resolve(
        cameraClientRequested: Bool,
        microphoneClientRequested: Bool,
        cameraTestRequested: Bool,
        microphoneTestRequested: Bool
    ) -> Self {
        if cameraClientRequested || microphoneClientRequested {
            return Self(
                cameraRequested: cameraClientRequested,
                microphoneRequested: microphoneClientRequested,
                cameraTestActive: false,
                microphoneTestActive: false
            )
        }
        return Self(
            cameraRequested: cameraTestRequested,
            microphoneRequested: microphoneTestRequested,
            cameraTestActive: cameraTestRequested,
            microphoneTestActive: microphoneTestRequested
        )
    }
}
