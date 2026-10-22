#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import TilePilot

final class WorkAreaGeometryTests: XCTestCase {
    // The 3840 × 2160 external display sits above the built-in one, so yabai reports a negative y.
    private let samsungFrame = CGRect(x: -687, y: -2160, width: 3840, height: 2160)

    func testSuggestedAreaIsLowerCenter2560x1440OnLargeDisplay() {
        let normalized = WorkAreaGeometry.suggestedNormalizedRect(displaySize: samsungFrame.size)
        let area = WorkAreaGeometry.resolve(normalizedRect: normalized, displayFrame: samsungFrame, visibleFrame: samsungFrame)
        XCTAssertEqual(area, CGRect(x: -47, y: -1620, width: 2560, height: 1440))
    }

    func testSuggestedAreaFallsBackToEightyPercentOnSmallerDisplay() {
        let normalized = WorkAreaGeometry.suggestedNormalizedRect(displaySize: CGSize(width: 2294, height: 1432))
        XCTAssertEqual(normalized.width * 2294, 1835, accuracy: 1)
        XCTAssertEqual(normalized.height * 1432, 1146, accuracy: 1)
    }

    func testResolveStaysOutOfMenuBarAndDock() {
        let display = CGRect(x: 0, y: 0, width: 2294, height: 1432)
        let visible = CGRect(x: 0, y: 30, width: 2294, height: 1343)
        let area = WorkAreaGeometry.resolve(
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            displayFrame: display,
            visibleFrame: visible
        )
        XCTAssertEqual(area, visible)
    }

    func testResolveGrowsTinyAreaToMinimumSizeInsideDisplay() {
        let area = WorkAreaGeometry.resolve(
            normalizedRect: CGRect(x: 0.99, y: 0.99, width: 0.005, height: 0.005),
            displayFrame: samsungFrame,
            visibleFrame: samsungFrame
        )
        XCTAssertEqual(area.width, 640)
        XCTAssertEqual(area.height, 400)
        XCTAssertTrue(samsungFrame.contains(area))
    }

    func testSystemBarSitsAboveTheWorkAreaWhenThereIsRoom() {
        let visible = CGRect(x: -687, y: -2130, width: 3840, height: 2130)
        let workArea = CGRect(x: -47, y: -1620, width: 2560, height: 1440)
        let layout = WorkAreaGeometry.systemBarLayout(workArea: workArea, visibleFrame: visible, barHeight: 30)
        XCTAssertTrue(layout.isAboveWorkArea)
        XCTAssertEqual(layout.bar, CGRect(x: -47, y: -1650, width: 2560, height: 30))
        XCTAssertEqual(layout.windowArea, workArea)
        // Padding for tiled windows is unchanged when the bar is above the area.
        let padding = WorkAreaGeometry.yabaiPadding(workArea: layout.windowArea, visibleFrame: visible, outerPadding: 0)
        XCTAssertEqual(padding, WorkAreaPadding(top: 510, bottom: 180, left: 640, right: 640))
    }

    func testSystemBarMovesInsideWhenTheWorkAreaTouchesTheMenuBar() {
        let visible = CGRect(x: 0, y: 30, width: 2294, height: 1343)
        let workArea = CGRect(x: 0, y: 40, width: 2294, height: 1333)
        let layout = WorkAreaGeometry.systemBarLayout(workArea: workArea, visibleFrame: visible, barHeight: 30)
        XCTAssertFalse(layout.isAboveWorkArea)
        XCTAssertEqual(layout.bar, CGRect(x: 0, y: 40, width: 2294, height: 30))
        XCTAssertEqual(layout.windowArea, CGRect(x: 0, y: 70, width: 2294, height: 1303))
        let padding = WorkAreaGeometry.yabaiPadding(workArea: layout.windowArea, visibleFrame: visible, outerPadding: 0)
        XCTAssertEqual(padding.top, 40)
    }

    func testAppKitConversionInvertsTopLeftConversion() {
        let primaryMaxY: CGFloat = 1432
        let bar = CGRect(x: -47, y: -1650, width: 2560, height: 30)
        let appKit = WorkAreaGeometry.appKitRect(fromTopLeft: bar, primaryScreenMaxY: primaryMaxY)
        XCTAssertEqual(appKit, CGRect(x: -47, y: 1432 + 1650 - 30, width: 2560, height: 30))
        XCTAssertEqual(WorkAreaGeometry.topLeftRect(fromAppKit: appKit, primaryScreenMaxY: primaryMaxY), bar)
    }

    func testPaddingMeasuresFromVisibleFrameAndAddsScreenEdgePadding() {
        let area = CGRect(x: -47, y: -1620, width: 2560, height: 1440)
        XCTAssertEqual(
            WorkAreaGeometry.yabaiPadding(workArea: area, visibleFrame: samsungFrame, outerPadding: 0),
            WorkAreaPadding(top: 540, bottom: 180, left: 640, right: 640)
        )
        XCTAssertEqual(
            WorkAreaGeometry.yabaiPadding(workArea: area, visibleFrame: samsungFrame, outerPadding: 12),
            WorkAreaPadding(top: 552, bottom: 192, left: 652, right: 652)
        )
    }

    func testPaddingNeverGoesNegative() {
        let visible = CGRect(x: 0, y: 30, width: 1000, height: 800)
        let areaSpillingPastVisible = CGRect(x: -10, y: 0, width: 1020, height: 840)
        XCTAssertEqual(
            WorkAreaGeometry.yabaiPadding(workArea: areaSpillingPastVisible, visibleFrame: visible, outerPadding: 4),
            WorkAreaPadding(top: 4, bottom: 4, left: 4, right: 4)
        )
    }

    func testContainedFrameIsNilWhenInsideOrWithinTolerance() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertNil(WorkAreaGeometry.containedFrame(windowFrame: CGRect(x: 100, y: 100, width: 400, height: 300), workArea: area))
        XCTAssertNil(WorkAreaGeometry.containedFrame(windowFrame: CGRect(x: -1, y: 0, width: 1001, height: 800), workArea: area))
    }

    func testContainedFrameMovesOverflowBackInside() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(
            WorkAreaGeometry.containedFrame(windowFrame: CGRect(x: 900, y: 700, width: 300, height: 200), workArea: area),
            CGRect(x: 700, y: 600, width: 300, height: 200)
        )
        XCTAssertEqual(
            WorkAreaGeometry.containedFrame(windowFrame: CGRect(x: -50, y: -20, width: 300, height: 200), workArea: area),
            CGRect(x: 0, y: 0, width: 300, height: 200)
        )
    }

    func testContainedFrameShrinksOversizedWindows() {
        let area = CGRect(x: 100, y: 50, width: 1000, height: 800)
        XCTAssertEqual(
            WorkAreaGeometry.containedFrame(windowFrame: CGRect(x: 0, y: 0, width: 1500, height: 1000), workArea: area),
            area
        )
    }

    func testContainedFrameKeepsSizeWhenWindowCannotResize() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let target = WorkAreaGeometry.containedFrame(
            windowFrame: CGRect(x: 300, y: 100, width: 1200, height: 600),
            workArea: area,
            canResize: false
        )
        XCTAssertEqual(target, CGRect(x: 0, y: 100, width: 1200, height: 600))
    }

    func testContainedFrameNeverShrinksBelowMinimumSize() {
        let tinyArea = CGRect(x: 0, y: 0, width: 50, height: 40)
        let target = WorkAreaGeometry.containedFrame(windowFrame: CGRect(x: 10, y: 10, width: 200, height: 100), workArea: tinyArea)
        XCTAssertEqual(target?.size, CGSize(width: 80, height: 60))

        // Small windows are moved, never enlarged.
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let small = WorkAreaGeometry.containedFrame(windowFrame: CGRect(x: 990, y: 10, width: 40, height: 30), workArea: area)
        XCTAssertEqual(small, CGRect(x: 960, y: 10, width: 40, height: 30))
    }

    func testFillFrameIsTheWorkArea() {
        let area = CGRect(x: -47, y: -1620, width: 2560, height: 1440)
        XCTAssertEqual(WorkAreaGeometry.fillFrame(workArea: area), area)
    }

    func testAppKitFramesConvertToYabaiCoordinates() {
        let appKitSamsung = CGRect(x: -687, y: 1432, width: 3840, height: 2160)
        XCTAssertEqual(WorkAreaGeometry.topLeftRect(fromAppKit: appKitSamsung, primaryScreenMaxY: 1432), samsungFrame)
    }

    func testPositionPresetsKeepSizeAndPlaceVertically() {
        let size = CGSize(width: 2560, height: 1440)
        let bottom = WorkAreaGeometry.normalizedRect(size: size, position: .bottomCenter, displaySize: samsungFrame.size)
        XCTAssertEqual(bottom.maxY, 1, accuracy: 0.0001)
        XCTAssertEqual(bottom.midX, 0.5, accuracy: 0.0001)
        let center = WorkAreaGeometry.normalizedRect(size: size, position: .center, displaySize: samsungFrame.size)
        XCTAssertEqual(center.midY, 0.5, accuracy: 0.0001)
    }

    func testClampedNormalizedRectStaysOnDisplayAtMinimumSize() {
        let clamped = WorkAreaGeometry.clampedNormalizedRect(
            CGRect(x: 0.9, y: -0.2, width: 0.01, height: 2),
            displaySize: samsungFrame.size
        )
        XCTAssertEqual(clamped.width, 640.0 / 3840.0, accuracy: 0.0001)
        XCTAssertEqual(clamped.height, 1)
        XCTAssertLessThanOrEqual(clamped.maxX, 1)
        XCTAssertEqual(clamped.minY, 0)
    }

    // Frames recorded on the Samsung while Mission Control and Show Desktop were open.
    private let chrome = CGRect(x: 227, y: -1410, width: 1528, height: 1041)
    private let signal = CGRect(x: 223, y: -1745, width: 317, height: 368)
    private let smallChrome = CGRect(x: -574, y: -1745, width: 606, height: 454)

    func testMissionControlThumbnailsLookTransformed() {
        XCTAssertTrue(WorkAreaGeometry.windowServerLooksTransformed([
            (CGRect(x: 329, y: -823, width: 1180, height: 804), chrome),
            (CGRect(x: 215, y: -2033, width: 245, height: 285), signal),
        ]))
    }

    func testShowDesktopMoveWithoutResizeLooksTransformed() {
        XCTAssertTrue(WorkAreaGeometry.windowServerLooksTransformed([
            (CGRect(x: -1281, y: -1957, width: 606, height: 454), smallChrome),
        ]))
    }

    func testMatchingFramesAndSmallJitterDoNotLookTransformed() {
        XCTAssertFalse(WorkAreaGeometry.windowServerLooksTransformed([]))
        XCTAssertFalse(WorkAreaGeometry.windowServerLooksTransformed([
            (chrome, chrome),
            (smallChrome.offsetBy(dx: 3, dy: 0), smallChrome),
            (signal.insetBy(dx: -1, dy: -1), signal),
        ]))
    }

    func testOneOddWindowAmongSeveralDoesNotBlockContainment() {
        XCTAssertFalse(WorkAreaGeometry.windowServerLooksTransformed([
            (chrome, chrome),
            (CGRect(x: 223, y: -1745, width: 330, height: 368), signal),
            (smallChrome, smallChrome),
        ]))
    }
}
#endif
