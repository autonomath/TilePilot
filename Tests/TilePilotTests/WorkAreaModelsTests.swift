#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import TilePilot

final class WorkAreaModelsTests: XCTestCase {
    private func configuration(uuid: String?, name: String = "SAMSUNG", width: Double = 3840, height: Double = 2160) -> WorkAreaConfiguration {
        WorkAreaConfiguration(
            displayUUID: uuid,
            displayName: name,
            displayWidth: width,
            displayHeight: height,
            normalizedRect: CGRect(x: 1.0 / 6.0, y: 0.25, width: 2.0 / 3.0, height: 2.0 / 3.0)
        )
    }

    func testCodableRoundTrip() throws {
        var original = configuration(uuid: "abcdef01-2345-4678-9abc-def012345678")
        original.containmentEnabled = false
        original.excludedApps = ["Finder"]
        let decoded = try JSONDecoder().decode(WorkAreaConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.displayUUID, "ABCDEF01-2345-4678-9ABC-DEF012345678")
    }

    func testOlderPayloadDecodesWithDefaults() throws {
        let json = """
        {"displayUUID":"ABC","displayName":"SAMSUNG","normalizedX":0.1,"normalizedY":0.2,"normalizedWidth":0.5,"normalizedHeight":0.5}
        """
        let decoded = try JSONDecoder().decode(WorkAreaConfiguration.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.enabled)
        XCTAssertTrue(decoded.containmentEnabled)
        XCTAssertEqual(decoded.excludedApps, [])
        XCTAssertEqual(decoded.normalizedRect, CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5))
    }

    func testMatchingPrefersUUID() {
        let configurations = [configuration(uuid: "AAA"), configuration(uuid: "BBB")]
        let index = WorkAreaConfiguration.matchIndex(
            displayUUID: "bbb",
            displayName: "SAMSUNG",
            width: 3840,
            height: 2160,
            connectedUUIDs: ["AAA", "BBB"],
            in: configurations
        )
        XCTAssertEqual(index, 1)
    }

    func testMatchingFallsBackToSameSizeOrphanedConfiguration() {
        // The monitor came back with a new UUID; its old configuration is no longer connected.
        let configurations = [configuration(uuid: "BUILTIN", name: "Color LCD", width: 3840, height: 2160), configuration(uuid: "OLD")]
        let index = WorkAreaConfiguration.matchIndex(
            displayUUID: "NEW",
            displayName: "SAMSUNG",
            width: 3840,
            height: 2160,
            connectedUUIDs: ["NEW", "BUILTIN"],
            in: configurations
        )
        XCTAssertEqual(index, 1)

        let noMatch = WorkAreaConfiguration.matchIndex(
            displayUUID: "NEW",
            displayName: "SAMSUNG",
            width: 2560,
            height: 1440,
            connectedUUIDs: ["NEW", "BUILTIN"],
            in: configurations
        )
        XCTAssertNil(noMatch)
    }

    func testNormalizedRectScalesWithDisplayResolution() {
        let saved = configuration(uuid: "AAA")
        let area = WorkAreaGeometry.resolve(
            normalizedRect: saved.normalizedRect,
            displayFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: nil
        )
        XCTAssertEqual(area.minX, 427, accuracy: 1)
        XCTAssertEqual(area.minY, 360, accuracy: 1)
        XCTAssertEqual(area.width, 1707, accuracy: 1)
        XCTAssertEqual(area.height, 960, accuracy: 1)
    }

    func testExcludedAppsMatchLikeAppRules() {
        var saved = configuration(uuid: "AAA")
        saved.excludedApps = ["Google Chrome"]
        XCTAssertTrue(saved.excludesApp("google chrome"))
        XCTAssertFalse(saved.excludesApp("Safari"))
    }

    @MainActor
    func testContainmentSkipsTiledWindowsButIncludesWindowsOnFloatingDesktops() {
        let saved = configuration(uuid: "AAA")
        func window(floating: Bool, subrole: String = "AXStandardWindow", fullscreen: Bool = false) -> WindowState {
            WindowState(
                id: 1, pid: 42, app: "Notes", space: 3, display: 2,
                frameX: 0, frameY: 0, frameW: 800, frameH: 600,
                floating: floating, hasAXReference: true, canMove: true, canResize: true,
                title: "Note", role: "AXWindow", subrole: subrole,
                focused: false, isVisible: true, isMinimized: false, isHidden: false,
                source: .yabai, lastUpdatedAt: Date(), isNativeFullscreen: fullscreen
            )
        }
        func candidate(_ window: WindowState, layout: String) -> Bool {
            WorkAreaContainmentCoordinator.isCandidate(
                window, configuration: saved, visibleSpaces: [3], spaceLayout: layout, allowedWindowIDs: []
            )
        }

        XCTAssertFalse(candidate(window(floating: false), layout: "bsp"), "padding keeps tiled windows inside")
        XCTAssertTrue(candidate(window(floating: true), layout: "bsp"))
        XCTAssertTrue(candidate(window(floating: false), layout: "float"), "yabai reports managed windows on float desktops as not floating")
        XCTAssertFalse(candidate(window(floating: true, fullscreen: true), layout: "float"))
        XCTAssertFalse(candidate(window(floating: true, subrole: "AXDialog"), layout: "float"))
    }

    @MainActor
    func testContainmentStillMovesWindowsYabaiLostTrackOf() {
        let saved = configuration(uuid: "AAA")
        // After yabai restarts while the Mac is locked it reports existing windows with no
        // Accessibility reference, no role, and "can't move", although they are on screen.
        func window(hasAXReference: Bool, canMove: Bool, onScreen: Bool) -> WindowState {
            WindowState(
                id: 1, pid: 42, app: "Wire", space: 3, display: 2,
                frameX: -400, frameY: -1923, frameW: 1285, frameH: 1135,
                floating: false, hasAXReference: hasAXReference, canMove: canMove, canResize: canMove,
                title: "Wire", role: hasAXReference ? "AXWindow" : "", subrole: hasAXReference ? "AXStandardWindow" : "",
                focused: false, isVisible: true, isMinimized: false, isHidden: false,
                hasWindowServerMatch: onScreen,
                source: .yabai, lastUpdatedAt: Date()
            )
        }
        func candidate(_ window: WindowState) -> Bool {
            WorkAreaContainmentCoordinator.isCandidate(
                window, configuration: saved, visibleSpaces: [3], spaceLayout: "float", allowedWindowIDs: []
            )
        }

        XCTAssertTrue(candidate(window(hasAXReference: false, canMove: false, onScreen: true)), "lost by yabai, moved through Accessibility")
        XCTAssertFalse(candidate(window(hasAXReference: true, canMove: false, onScreen: true)), "yabai knows this window cannot move")
        XCTAssertFalse(candidate(window(hasAXReference: false, canMove: false, onScreen: false)), "not on screen")
    }
}
#endif
