#if canImport(XCTest)
import AppKit
import SwiftUI
import XCTest
@testable import TilePilot

final class TilePilotTabTests: XCTestCase {
    func testVisibleTabOrderAndTitlesStayStable() {
        XCTAssertEqual(
            TilePilotTab.visibleTabs,
            [
                .now,
                .windowBehavior,
                .actions,
                .templates,
                .workSets,
                .appearance,
                .files,
                .howItWorks,
                .system,
            ]
        )
        XCTAssertEqual(
            TilePilotTab.visibleTabs.map(\.title),
            [
                "Overview",
                "Behaviors",
                "Actions & Shortcuts",
                "Templates",
                "Work Sets",
                "Appearance",
                "Config Files",
                "How It Works",
                "System",
            ]
        )
    }

    func testLegacyRoutesCanonicalizeToVisibleTabs() {
        XCTAssertEqual(TilePilotTab.shortcuts.canonicalVisibleTab, .actions)
        XCTAssertEqual(TilePilotTab.config.canonicalVisibleTab, .system)
        XCTAssertEqual(TilePilotTab.health.canonicalVisibleTab, .system)
        XCTAssertEqual(TilePilotTab.setup.canonicalVisibleTab, .system)
        XCTAssertEqual(TilePilotTab.logs.canonicalVisibleTab, .system)

        for tab in TilePilotTab.visibleTabs {
            XCTAssertEqual(tab.canonicalVisibleTab, tab)
        }
    }

    func testKeyboardNavigationMovesBetweenTabsAndStopsAtBoundaries() {
        XCTAssertEqual(TilePilotTab.adjacentVisibleTab(from: .now, moving: .previous), .now)
        XCTAssertEqual(TilePilotTab.adjacentVisibleTab(from: .now, moving: .next), .windowBehavior)
        XCTAssertEqual(TilePilotTab.adjacentVisibleTab(from: .actions, moving: .next), .templates)
        XCTAssertEqual(TilePilotTab.adjacentVisibleTab(from: .system, moving: .previous), .howItWorks)
        XCTAssertEqual(TilePilotTab.adjacentVisibleTab(from: .system, moving: .next), .system)
        XCTAssertEqual(TilePilotTab.adjacentVisibleTab(from: .shortcuts, moving: .next), .templates)
        XCTAssertEqual(TilePilotTab.adjacentVisibleTab(from: .config, moving: .previous), .howItWorks)
    }

    @MainActor
    func testHostedTabStripFitsMinimumSlotWithoutNativeSegmentedControl() {
        let hostingView = NSHostingView(rootView: TilePilotTabStrip(selection: .constant(.now)))
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: TilePilotTabStrip.maximumWidth,
            height: TilePilotTabStrip.height
        )
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertLessThan(hostingView.fittingSize.width, TilePilotTabStrip.maximumWidth)
        XCTAssertFalse(containsNativeSegmentedControl(in: hostingView))
    }

    @MainActor
    private func containsNativeSegmentedControl(in view: NSView) -> Bool {
        if String(describing: type(of: view)).localizedCaseInsensitiveContains("segmentedcontrol") {
            return true
        }
        return view.subviews.contains { containsNativeSegmentedControl(in: $0) }
    }
}
#endif
