import XCTest
@testable import AICameraCore

final class LatestValueSlotTests: XCTestCase {
    func testEmptySlotReturnsNil() {
        let slot = LatestValueSlot<Int>()
        XCTAssertNil(slot.latest())
        XCTAssertNil(slot.fresh(maxAge: 1))
    }

    func testLatestValueWins() {
        let slot = LatestValueSlot<Int>()
        slot.store(1)
        slot.store(2)
        XCTAssertEqual(slot.latest()?.element, 2)
    }

    func testFreshHonoursAge() {
        let slot = LatestValueSlot<Int>()
        let now = Date()
        slot.store(1, at: now.addingTimeInterval(-0.5))
        slot.store(2, at: now)
        XCTAssertEqual(slot.fresh(maxAge: 1, now: now), 2)
        XCTAssertNil(slot.fresh(maxAge: 0.1, now: now.addingTimeInterval(0.2)))
    }

    func testClearRemovesValue() {
        let slot = LatestValueSlot<Int>()
        slot.store(1)
        slot.clear()
        XCTAssertNil(slot.latest())
        XCTAssertNil(slot.fresh(maxAge: 10))
    }

    func testStoresAfterClear() {
        let slot = LatestValueSlot<String>()
        slot.clear()
        slot.store("a")
        XCTAssertEqual(slot.latest()?.element, "a")
    }
}
