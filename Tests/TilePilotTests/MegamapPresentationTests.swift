#if canImport(XCTest)
import AppKit
import XCTest
@testable import TilePilot

final class MegamapPresentationTests: XCTestCase {
    func testMissingDesktopDataShowsLoadingRatherThanPermissionAdvice() {
        XCTAssertEqual(MegamapEmptyState(snapshot: nil), .loading)
    }

    func testFallbackAndDegradedDesktopDataExplainConnectionFailure() {
        XCTAssertEqual(MegamapEmptyState(snapshot: snapshot(source: .fallback)), .desktopDataUnavailable)
        XCTAssertEqual(MegamapEmptyState(snapshot: snapshot(degraded: true)), .desktopDataUnavailable)
    }

    func testOneDesktopPerDisplayExplainsMultipleDesktopRequirement() {
        XCTAssertEqual(MegamapEmptyState(snapshot: snapshot()), .needsMultipleDesktops)
    }

    @MainActor
    func testOpeningWithoutSectionsStillShowsAMegamapWindow() {
        _ = NSApplication.shared
        let model = AppModel()
        let controller = MegamapWindowController(model: model)
        defer { controller.hideImmediately() }

        controller.showAndFocus()

        let windows = NSApp.windows.filter { $0.title == "MegaMap" && $0.isVisible }
        XCTAssertEqual(windows.count, 1)
        XCTAssertNotNil(windows.first?.contentViewController)

        controller.showAndFocus()
        XCTAssertEqual(NSApp.windows.filter { $0.title == "MegaMap" && $0.isVisible }.count, 1)
    }

    private func snapshot(source: StateSourceQuality = .yabai, degraded: Bool = false) -> LiveStateSnapshot {
        LiveStateSnapshot(
            displays: [1, 2].map {
                DisplayState(id: $0, name: "Display \($0)", frameX: 0, frameY: 0, frameW: 1440, frameH: 900,
                             focused: $0 == 1, windowCount: 0, source: source, lastUpdatedAt: .distantPast)
            },
            spaces: [1, 2].map {
                SpaceState(index: $0, label: nil, displayId: $0, focused: $0 == 1, visible: true,
                           layout: "bsp", windowCount: 0, source: source, lastUpdatedAt: .distantPast)
            },
            windows: [],
            fallbackDisplays: [],
            source: source,
            lastUpdatedAt: .distantPast,
            degraded: degraded,
            degradedReason: degraded ? "Desktop query failed" : nil,
            yabaiWindowTotal: 0,
            fallbackWindowTotal: 0,
            consecutiveMismatchSamples: 0,
            consecutiveHealthySamples: 0,
            lastErrorMessage: nil
        )
    }
}
#endif
