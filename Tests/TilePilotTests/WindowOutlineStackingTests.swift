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

    func testOneOutlinePerAppPrefersStandardThenFocusedThenFrontWindow() {
        func window(_ id: Int, pid: Int, subrole: String = "AXStandardWindow", order: Int? = nil) -> WindowState {
            WindowState(
                id: id, pid: pid, app: "App\(pid)", space: 1, display: 1,
                frameX: 0, frameY: 0, frameW: 800, frameH: 600,
                floating: true, hasAXReference: true, canMove: true, canResize: true,
                title: "", role: "AXWindow", subrole: subrole,
                focused: false, isVisible: true, isMinimized: false, isHidden: false,
                windowServerOrderIndex: order, source: .yabai, lastUpdatedAt: Date()
            )
        }
        let codexMain = window(1, pid: 10, order: 5)
        let codexOverlay = window(2, pid: 10, subrole: "AXDialog", order: 0)
        let chromeBack = window(3, pid: 20, order: 4)
        let chromeFront = window(4, pid: 20, order: 1)
        let all = [codexMain, codexOverlay, chromeBack, chromeFront]

        XCTAssertEqual(AppModel.mainWindowPerApp(all, focusedID: nil).map(\.id), [1, 4])
        XCTAssertEqual(AppModel.mainWindowPerApp(all, focusedID: 2).map(\.id), [1, 4], "a focused helper keeps the outline on the main window")
        XCTAssertEqual(AppModel.mainWindowPerApp(all, focusedID: 3).map(\.id), [1, 3])
    }
}
#endif
