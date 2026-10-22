#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import TilePilot

final class RecentWindowTilerInventoryPolicyTests: XCTestCase {
    private let browserFrame = CGRect(x: 921, y: -1080, width: 1920, height: 1080)

    func testChromeTooltipIsExcludedEvenWithYabaiMoveSupport() {
        XCTAssertFalse(RecentWindowTilerInventoryPolicy.supportsRole(role: "AXHelpTag", subrole: ""))
        XCTAssertFalse(RecentWindowTilerInventoryPolicy.supportsRole(role: "AXWindow", subrole: "AXDialog"))
    }

    func testStandardAndMissingWindowMetadataRemainEligible() {
        XCTAssertTrue(RecentWindowTilerInventoryPolicy.supportsRole(role: "AXWindow", subrole: "AXStandardWindow"))
        XCTAssertTrue(RecentWindowTilerInventoryPolicy.supportsRole(role: "AXWindow", subrole: ""))
        XCTAssertTrue(RecentWindowTilerInventoryPolicy.supportsRole(role: "", subrole: ""))
    }

    func testUntitledTooltipCannotBorrowNearestBrowserTitle() {
        let tooltipFrame = CGRect(x: 419, y: -961, width: 136, height: 35)
        let windows = [descriptor(title: "MPay", frame: browserFrame)]
        XCTAssertNil(match(title: "", frame: tooltipFrame, windows: windows))
    }

    func testDistinctWindowsWithSameTitleMatchTheirOwnFrames() {
        let otherFrame = CGRect(x: -999, y: -1080, width: 1920, height: 1080)
        let windows = [descriptor(title: "MPay", frame: otherFrame), descriptor(title: "MPay", frame: browserFrame)]
        XCTAssertEqual(match(title: "MPay", frame: otherFrame, windows: windows), 0)
        XCTAssertEqual(match(title: "MPay", frame: browserFrame, windows: windows), 1)
    }

    func testAmbiguousUntitledWindowsHaveNoFallbackMatch() {
        let windows = [descriptor(title: "", frame: browserFrame), descriptor(title: "", frame: browserFrame)]
        XCTAssertNil(match(title: "", frame: browserFrame, windows: windows))
        XCTAssertNil(match(title: "", frame: browserFrame, windows: [descriptor(title: "MPay", frame: nil)]))
    }

    func testUntitledRealWindowMatchesWithSmallGeometryDrift() {
        let drifted = browserFrame.offsetBy(dx: 4, dy: -3)
        XCTAssertEqual(match(title: "", frame: browserFrame, windows: [descriptor(title: "", frame: drifted)]), 0)
    }

    func testUniqueTitleStillMatchesWhenYabaiFrameLags() {
        XCTAssertEqual(match(title: " MPay ", frame: .zero, windows: [descriptor(title: "MPay", frame: browserFrame)]), 0)
    }

    private func descriptor(title: String, frame: CGRect?) -> RecentWindowTilerInventoryPolicy.AccessibilityWindow {
        .init(title: title, frame: frame)
    }

    private func match(
        title: String,
        frame: CGRect,
        windows: [RecentWindowTilerInventoryPolicy.AccessibilityWindow]
    ) -> Int? {
        RecentWindowTilerInventoryPolicy.matchingAccessibilityWindowIndex(title: title, frame: frame, windows: windows)
    }
}
#endif
