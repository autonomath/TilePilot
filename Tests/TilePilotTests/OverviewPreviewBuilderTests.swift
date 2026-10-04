import CoreGraphics
#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class OverviewPreviewBuilderTests: XCTestCase {
    func testBuildOrdersFocusedDisplayFirstAndSkipsExcludedWindows() {
        let snapshot = LiveStateSnapshot(
            displays: [
                DisplayState(
                    id: 2,
                    name: "External",
                    frameX: 1440,
                    frameY: 0,
                    frameW: 2560,
                    frameH: 1440,
                    focused: false,
                    windowCount: 1,
                    source: .yabai,
                    lastUpdatedAt: .distantPast
                ),
                DisplayState(
                    id: 1,
                    name: "Built-in",
                    frameX: 0,
                    frameY: 0,
                    frameW: 1440,
                    frameH: 900,
                    focused: true,
                    windowCount: 2,
                    source: .yabai,
                    lastUpdatedAt: .distantPast
                ),
            ],
            spaces: [
                SpaceState(
                    index: 1,
                    label: nil,
                    displayId: 1,
                    focused: true,
                    visible: true,
                    layout: "bsp",
                    windowCount: 2,
                    source: .yabai,
                    lastUpdatedAt: .distantPast
                ),
                SpaceState(
                    index: 2,
                    label: nil,
                    displayId: 2,
                    focused: false,
                    visible: false,
                    layout: "bsp",
                    windowCount: 1,
                    source: .yabai,
                    lastUpdatedAt: .distantPast
                ),
            ],
            windows: [
                WindowState(
                    id: 101,
                    pid: 10,
                    app: "Codex",
                    space: 1,
                    display: 1,
                    frameX: 100,
                    frameY: 80,
                    frameW: 800,
                    frameH: 600,
                    floating: false,
                    hasAXReference: true,
                    canMove: true,
                    canResize: true,
                    title: "Main",
                    focused: true,
                    isVisible: true,
                    isMinimized: false,
                    isHidden: false,
                    source: .yabai,
                    lastUpdatedAt: .distantPast
                ),
                WindowState(
                    id: 102,
                    pid: 11,
                    app: "Hidden Helper",
                    space: 1,
                    display: 1,
                    frameX: 120,
                    frameY: 120,
                    frameW: 200,
                    frameH: 100,
                    floating: true,
                    hasAXReference: true,
                    canMove: true,
                    canResize: true,
                    title: "Ignore Me",
                    focused: false,
                    isVisible: true,
                    isMinimized: false,
                    isHidden: false,
                    source: .yabai,
                    lastUpdatedAt: .distantPast
                ),
                WindowState(
                    id: 201,
                    pid: 20,
                    app: "Safari",
                    space: 2,
                    display: 2,
                    frameX: 1500,
                    frameY: 100,
                    frameW: 900,
                    frameH: 700,
                    floating: true,
                    hasAXReference: true,
                    canMove: true,
                    canResize: true,
                    title: "External",
                    focused: false,
                    isVisible: true,
                    isMinimized: false,
                    isHidden: false,
                    source: .yabai,
                    lastUpdatedAt: .distantPast
                ),
            ],
            fallbackDisplays: [],
            source: .yabai,
            lastUpdatedAt: .distantPast,
            degraded: false,
            degradedReason: nil,
            yabaiWindowTotal: 3,
            fallbackWindowTotal: nil,
            consecutiveMismatchSamples: 0,
            consecutiveHealthySamples: 1,
            lastErrorMessage: nil
        )

        let previews = OverviewPreviewBuilder.build(snapshot: snapshot) { $0.id == 102 }

        XCTAssertEqual(previews.map(\.id), [1, 2])
        XCTAssertEqual(previews.first?.desktops.first?.tilingEnabled, true)
        XCTAssertEqual(previews.first?.desktops.first?.windows.map(\.id), [101])
        XCTAssertEqual(previews.last?.desktops.first?.windows.map(\.id), [201])
        XCTAssertEqual(previews.first?.desktops.first?.windows.first?.desktopIndex, 1)
    }

    func testNormalizedPreviewClampsWindowsToDisplayBounds() {
        let display = DisplayState(
            id: 1,
            name: "Built-in",
            frameX: 100,
            frameY: 50,
            frameW: 1000,
            frameH: 500,
            focused: true,
            windowCount: 1,
            source: .yabai,
            lastUpdatedAt: .distantPast
        )
        let window = WindowState(
            id: 77,
            pid: 7,
            app: "Browser",
            space: 1,
            display: 1,
            frameX: 50,
            frameY: 25,
            frameW: 1200,
            frameH: 700,
            floating: true,
            hasAXReference: true,
            canMove: true,
            canResize: true,
            title: "Clamped",
            focused: false,
            isVisible: true,
            isMinimized: false,
            isHidden: false,
            source: .yabai,
            lastUpdatedAt: .distantPast
        )

        let preview = OverviewPreviewBuilder.normalizedPreview(for: window, in: display, desktopIndex: 1)

        XCTAssertNotNil(preview)
        XCTAssertEqual(preview?.desktopIndex, 1)
        XCTAssertEqual(preview?.normalizedX, 0, accuracy: 0.0001)
        XCTAssertEqual(preview?.normalizedY, 0, accuracy: 0.0001)
        XCTAssertEqual(preview?.normalizedW, 1, accuracy: 0.0001)
        XCTAssertEqual(preview?.normalizedH, 1, accuracy: 0.0001)
    }

    func testMiniMapGeometryAppliesMinimumTileSizeInsideCanvas() {
        let preview = OverviewWindowPreview(
            id: 1,
            app: "Tiny",
            title: "Tiny",
            desktopIndex: 1,
            floating: false,
            runtimeManageable: true,
            focused: false,
            visible: true,
            normalizedX: 0.95,
            normalizedY: 0.95,
            normalizedW: 0.01,
            normalizedH: 0.01
        )

        let frame = OverviewMiniMapGeometry.frame(for: preview, in: CGSize(width: 200, height: 100))

        XCTAssertGreaterThanOrEqual(frame.width, 0)
        XCTAssertGreaterThanOrEqual(frame.height, 0)
        XCTAssertLessThanOrEqual(frame.maxX, 200.0001)
        XCTAssertLessThanOrEqual(frame.maxY, 100.0001)
    }
}
#endif
