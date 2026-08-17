import XCTest
@testable import AICameraCore

final class PhysicalInputPolicyTests: XCTestCase {
    func testAcceptsKnownDirectHardwareTransports() {
        for transport in [
            "bltn", "pci ", "usb ", "1394", "blue", "blea", "hdmi", "dprt", "thun"
        ] {
            XCTAssertTrue(
                PhysicalInputPolicy.isEligible(transportType: fourCC(transport)),
                transport
            )
        }
    }

    func testRejectsSoftwareAggregateNetworkAndUnknownTransports() {
        for transport in ["virt", "grup", "fgrp", "ntwk", "airp", "othr"] {
            XCTAssertFalse(
                PhysicalInputPolicy.isEligible(transportType: fourCC(transport)),
                transport
            )
        }
        XCTAssertFalse(PhysicalInputPolicy.isEligible(transportType: 0))
    }

    func testRejectsAllContinuityCaptureTransports() {
        XCTAssertFalse(PhysicalInputPolicy.isEligible(transportType: fourCC("ccwd")))
        XCTAssertFalse(PhysicalInputPolicy.isEligible(transportType: fourCC("ccwl")))
        XCTAssertFalse(PhysicalInputPolicy.isEligible(transportType: fourCC("ccap")))
    }

    func testContinuityFlagOverridesOtherwiseEligibleTransport() {
        XCTAssertFalse(
            PhysicalInputPolicy.isEligible(
                transportType: fourCC("usb "),
                isContinuityDevice: true
            )
        )
    }

    func testKeepsEligibleSystemDefault() {
        XCTAssertEqual(
            PhysicalInputPolicy.resolvedDefault(
                preferredID: "usb-camera",
                eligibleIDs: ["built-in", "usb-camera"]
            ),
            "usb-camera"
        )
    }

    func testFallsBackWhenSystemDefaultIsExcluded() {
        XCTAssertEqual(
            PhysicalInputPolicy.resolvedDefault(
                preferredID: "ai-camera",
                eligibleIDs: ["built-in", "usb-camera"]
            ),
            "built-in"
        )
    }

    func testFallsBackWhenThereIsNoSystemPreferredDevice() {
        XCTAssertEqual(
            PhysicalInputPolicy.resolvedDefault(
                preferredID: Optional<String>.none,
                eligibleIDs: ["usb-camera"]
            ),
            "usb-camera"
        )
    }

    func testReturnsNilWhenNoPhysicalInputExists() {
        XCTAssertNil(
            PhysicalInputPolicy.resolvedDefault(
                preferredID: "ai-camera",
                eligibleIDs: [String]()
            )
        )
    }

    private func fourCC(_ value: String) -> UInt32 {
        value.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
