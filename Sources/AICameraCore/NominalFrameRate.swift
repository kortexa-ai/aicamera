import Foundation

public enum FrameRateDurationSelection: Equatable, Sendable {
    /// The requested frame duration lies inside the advertised range.
    case requested
    /// Use `AVFrameRateRange.minFrameDuration`, the fastest advertised rate.
    case minimumFrameDuration
    /// Use `AVFrameRateRange.maxFrameDuration`, the slowest advertised rate.
    case maximumFrameDuration
}

public struct NominalFrameRateMatch: Equatable, Sendable {
    public let actualFramesPerSecond: Double
    public let distance: Double
    public let durationSelection: FrameRateDurationSelection
}

public enum NominalFrameRateMatcher {
    /// Matches common nominal rates to nearby hardware rates such as 29.97 and 59.94.
    public static func match(
        requestedFPS: Double,
        minimumFPS: Double,
        maximumFPS: Double,
        relativeTolerance: Double = 0.002
    ) -> NominalFrameRateMatch? {
        guard requestedFPS.isFinite,
              minimumFPS.isFinite,
              maximumFPS.isFinite,
              relativeTolerance.isFinite,
              requestedFPS > 0,
              minimumFPS > 0,
              maximumFPS >= minimumFPS,
              relativeTolerance >= 0 else { return nil }

        let actualFramesPerSecond: Double
        let durationSelection: FrameRateDurationSelection
        if requestedFPS < minimumFPS {
            actualFramesPerSecond = minimumFPS
            durationSelection = .maximumFrameDuration
        } else if requestedFPS > maximumFPS {
            actualFramesPerSecond = maximumFPS
            durationSelection = .minimumFrameDuration
        } else {
            actualFramesPerSecond = requestedFPS
            durationSelection = .requested
        }

        let distance = abs(actualFramesPerSecond - requestedFPS)
        guard distance <= requestedFPS * relativeTolerance else { return nil }
        return NominalFrameRateMatch(
            actualFramesPerSecond: actualFramesPerSecond,
            distance: distance,
            durationSelection: durationSelection
        )
    }
}
