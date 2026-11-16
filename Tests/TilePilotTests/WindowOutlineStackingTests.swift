#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class WindowOutlineStackingTests: XCTestCase {
    func testOutlineNeedsReorderUnlessItSitsRightAboveItsWindow() {
        let stack = [90, 7, 10, 8, 20]
        XCTAssertTrue(WindowBadgeOverlayController.isDirectlyAbove(panel: 7, target: 10, in: stack))
        XCTAssertFalse(WindowBadgeOverlayController.isDirectlyAbove(panel: 8, target: 10, in: stack))
        XCTAssertFalse(WindowBadgeOverlayController.isDirectlyAbove(panel: 7, target: 90, in: stack))
        XCTAssertFalse(WindowBadgeOverlayController.isDirectlyAbove(panel: 7, target: 99, in: stack))
    }
}
#endif
