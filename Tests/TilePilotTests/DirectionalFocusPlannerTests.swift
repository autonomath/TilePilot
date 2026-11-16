#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import TilePilot

final class DirectionalFocusPlannerTests: XCTestCase {
    // A 2×2 grid in front of a big window that the grid hides completely.
    private let grid: [(id: Int, frame: CGRect)] = [
        (1, CGRect(x: 0, y: 0, width: 500, height: 400)),
        (2, CGRect(x: 500, y: 0, width: 500, height: 400)),
        (3, CGRect(x: 0, y: 400, width: 500, height: 400)),
        (4, CGRect(x: 500, y: 400, width: 500, height: 400)),
        (9, CGRect(x: 100, y: 100, width: 800, height: 600)),
    ]

    func testMovesWithinTheGridAndSkipsHiddenWindows() {
        XCTAssertEqual(DirectionalFocusPlanner.target(from: 1, toward: .right, among: grid), 2)
        XCTAssertEqual(DirectionalFocusPlanner.target(from: 1, toward: .down, among: grid), 3)
        XCTAssertEqual(DirectionalFocusPlanner.target(from: 4, toward: .left, among: grid), 3)
        XCTAssertEqual(DirectionalFocusPlanner.target(from: 4, toward: .up, among: grid), 2)
        XCTAssertNil(DirectionalFocusPlanner.target(from: 1, toward: .left, among: grid))
        XCTAssertNil(DirectionalFocusPlanner.target(from: 1, toward: .up, among: grid))
    }

    func testPartlyVisibleWindowBehindStillCounts() {
        // Window 1 snapped over the left half; 3 sticks out below it.
        let windows: [(id: Int, frame: CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 500, height: 600)),
            (2, CGRect(x: 500, y: 0, width: 500, height: 400)),
            (3, CGRect(x: 0, y: 400, width: 500, height: 400)),
        ]
        XCTAssertEqual(DirectionalFocusPlanner.target(from: 1, toward: .down, among: windows), 3)
        XCTAssertEqual(DirectionalFocusPlanner.target(from: 2, toward: .left, among: windows), 1)
    }

    func testWindowShowingOnlyAStripIsReachable() {
        // 2 sits behind 1 except for a 20% strip on its right.
        let windows: [(id: Int, frame: CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 900, height: 800)),
            (2, CGRect(x: 500, y: 0, width: 500, height: 400)),
        ]
        XCTAssertEqual(DirectionalFocusPlanner.target(from: 1, toward: .right, among: windows), 2)
    }
}
#endif
