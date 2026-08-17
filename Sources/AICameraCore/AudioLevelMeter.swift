import Foundation

public enum AudioLevelMeter {
    /// Maps a linear peak to a perceptual 0...1 meter with a configurable dB floor.
    public static func normalizedPeak(
        _ peak: Float,
        floorDecibels: Float = -60
    ) -> Float {
        guard peak.isFinite, peak > 0,
              floorDecibels.isFinite, floorDecibels < 0 else { return 0 }
        let decibels = 20 * log10(peak)
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }
}
