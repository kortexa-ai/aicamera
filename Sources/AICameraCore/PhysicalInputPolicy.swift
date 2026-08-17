import Foundation

/// Shared fail-safe filtering for hardware inputs used behind AI Camera's virtual devices.
public enum PhysicalInputPolicy {
    private static let physicalTransports: Set<UInt32> = [
        fourCC("bltn"), // Built in
        fourCC("pci "),
        fourCC("usb "),
        fourCC("1394"), // FireWire
        fourCC("blue"), // Bluetooth
        fourCC("blea"), // Bluetooth LE
        fourCC("hdmi"),
        fourCC("dprt"), // DisplayPort
        fourCC("thun")  // Thunderbolt
    ]

    /// Accepts only known direct-hardware transports. Software loopbacks, aggregates,
    /// network devices, unknown transports, and Continuity Capture devices fail closed.
    public static func isEligible(
        transportType: UInt32,
        isContinuityDevice: Bool = false
    ) -> Bool {
        !isContinuityDevice && physicalTransports.contains(transportType)
    }

    /// Keeps an eligible system default; otherwise selects the first eligible local input.
    public static func resolvedDefault<ID: Equatable>(
        preferredID: ID?,
        eligibleIDs: [ID]
    ) -> ID? {
        if let preferredID, eligibleIDs.contains(preferredID) {
            return preferredID
        }
        return eligibleIDs.first
    }

    private static func fourCC(_ value: String) -> UInt32 {
        value.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
