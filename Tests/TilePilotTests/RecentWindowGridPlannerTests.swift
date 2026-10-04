#if canImport(XCTest)
import CoreGraphics
import Foundation
import XCTest
@testable import TilePilot

final class RecentWindowGridPlannerTests: XCTestCase {
    func testOptimizedGridChoicesForCommonWindowCounts() {
        let expected: [Int: (rows: Int, cols: Int, spare: Int)] = [
            2: (1, 2, 0),
            3: (1, 3, 0),
            4: (2, 2, 0),
            5: (2, 3, 1),
            6: (2, 3, 0),
            7: (2, 4, 1),
            8: (2, 4, 0),
            9: (3, 3, 0),
            10: (2, 5, 0),
            11: (3, 4, 1),
            12: (3, 4, 0),
            13: (3, 5, 2),
        ]

        for count in 2...13 {
            let grid = RecentWindowGridPlanner.dimensions(windowCount: count, displayAspectRatio: 1.6)
            let spare = (grid.rows * grid.cols) - count

            XCTAssertEqual(grid.rows, expected[count]?.rows, "rows for \(count) windows")
            XCTAssertEqual(grid.cols, expected[count]?.cols, "cols for \(count) windows")
            XCTAssertEqual(spare, expected[count]?.spare, "spare cells for \(count) windows")
        }
    }

    func testSpareBottomCellsAreFilledByVerticalSpans() {
        assertSpannedPlacements(windowCount: 5, expectedSpannedIndexes: [2])
        assertSpannedPlacements(windowCount: 7, expectedSpannedIndexes: [3])
        assertSpannedPlacements(windowCount: 11, expectedSpannedIndexes: [7])
        assertSpannedPlacements(windowCount: 13, expectedSpannedIndexes: [8, 9])
    }

    func testPerfectGridsDoNotSpanWindows() {
        for count in [6, 8, 9, 10, 12] {
            let grid = RecentWindowGridPlanner.dimensions(windowCount: count, displayAspectRatio: 1.6)
            let placements = RecentWindowGridPlanner.placements(windowCount: count, rows: grid.rows, cols: grid.cols)

            XCTAssertEqual(placements.map(\.rowSpan), Array(repeating: 1, count: count), "row spans for \(count) windows")
        }
    }

    func testCandidateDisplayTextStripsRedundantBrowserAppSuffix() {
        let candidate = makeCandidate(
            app: "Google Chrome",
            title: "Release TilePilot v0.4.2 - Google Chrome"
        )

        XCTAssertEqual(candidate.primaryDisplayText, "Release TilePilot v0.4.2")
        XCTAssertEqual(candidate.secondaryDisplayText, "Google Chrome")
    }

    func testCandidateDisplayTextDoesNotRepeatSameAppTitle() {
        let candidate = makeCandidate(app: "OpenCode", title: "OpenCode")

        XCTAssertEqual(candidate.primaryDisplayText, "OpenCode")
        XCTAssertNil(candidate.secondaryDisplayText)
    }

    func testCandidateDisplayTextKeepsUsefulPlainTitle() {
        let candidate = makeCandidate(app: "Signal", title: "Signal (8)")

        XCTAssertEqual(candidate.primaryDisplayText, "Signal (8)")
        XCTAssertEqual(candidate.secondaryDisplayText, "Signal")
    }

    func testTemplatePlannerExactPlacementWinsOverCandidateOrder() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let left = WindowLayoutSlot(normalizedX: 0, normalizedY: 0, normalizedWidth: 0.5, normalizedHeight: 1)
        let right = WindowLayoutSlot(normalizedX: 0.5, normalizedY: 0, normalizedWidth: 0.5, normalizedHeight: 1)
        let template = makeTemplateOption(slots: [left, right])
        let rightFrame = RecentWindowTemplatePlanner.absoluteFrame(for: right, template: template, displayFrame: displayFrame)
        let leftFrame = RecentWindowTemplatePlanner.absoluteFrame(for: left, template: template, displayFrame: displayFrame)
        let frontmostRightWindow = makeCandidate(windowID: 2, app: "Signal", title: "Signal", frame: rightFrame)
        let leftWindow = makeCandidate(windowID: 1, app: "Google Chrome", title: "Docs", frame: leftFrame)

        let ordered = RecentWindowTemplatePlanner.orderedCandidateIDs(
            for: template,
            candidates: [frontmostRightWindow, leftWindow],
            displayFrame: displayFrame
        )

        XCTAssertEqual(ordered, [1, 2])
    }

    func testTemplatePlannerConstrainedSlotsPreferAllowedApps() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let constrained = WindowLayoutSlot(
            normalizedX: 0,
            normalizedY: 0,
            normalizedWidth: 0.5,
            normalizedHeight: 1,
            allowedApps: ["Signal"]
        )
        let any = WindowLayoutSlot(normalizedX: 0.5, normalizedY: 0, normalizedWidth: 0.5, normalizedHeight: 1)
        let template = makeTemplateOption(slots: [constrained, any])
        let chrome = makeCandidate(windowID: 1, app: "Google Chrome", title: "Docs")
        let signal = makeCandidate(windowID: 2, app: "Signal", title: "Signal")

        let ordered = RecentWindowTemplatePlanner.orderedCandidateIDs(
            for: template,
            candidates: [chrome, signal],
            displayFrame: displayFrame
        )

        XCTAssertEqual(ordered, [2, 1])
    }

    func testTemplatePlannerAnySlotsFillRemainingFrontToBackWindows() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let first = WindowLayoutSlot(normalizedX: 0, normalizedY: 0, normalizedWidth: 0.5, normalizedHeight: 1)
        let second = WindowLayoutSlot(normalizedX: 0.5, normalizedY: 0, normalizedWidth: 0.5, normalizedHeight: 1)
        let template = makeTemplateOption(slots: [first, second])
        let chrome = makeCandidate(windowID: 1, app: "Google Chrome", title: "Docs")
        let signal = makeCandidate(windowID: 2, app: "Signal", title: "Signal")
        let terminal = makeCandidate(windowID: 3, app: "iTerm2", title: "Build")

        let ordered = RecentWindowTemplatePlanner.orderedCandidateIDs(
            for: template,
            candidates: [chrome, signal, terminal],
            displayFrame: displayFrame
        )

        XCTAssertEqual(ordered, [1, 2])
    }

    func testTemplatePlannerAnySlotsMapFrontmostWindowToFrontmostLayer() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let backSlot = WindowLayoutSlot(
            normalizedX: 0,
            normalizedY: 0,
            normalizedWidth: 0.5,
            normalizedHeight: 1,
            zIndex: 0
        )
        let frontSlot = WindowLayoutSlot(
            normalizedX: 0.5,
            normalizedY: 0,
            normalizedWidth: 0.5,
            normalizedHeight: 1,
            zIndex: 2
        )
        let template = makeTemplateOption(slots: [backSlot, frontSlot])
        let frontmost = makeCandidate(
            windowID: 5,
            app: "Google Chrome",
            title: "Docs",
            frontToBackOrder: 0
        )
        let behind = makeCandidate(
            windowID: 10,
            app: "iTerm2",
            title: "Build",
            frontToBackOrder: 1
        )

        let slotWindowIDs = RecentWindowTemplatePlanner.slotWindowIDs(
            for: template,
            candidates: [frontmost, behind],
            displayFrame: displayFrame
        )

        XCTAssertEqual(slotWindowIDs, [10, 5])
    }

    func testTemplatePlannerKeepsEmptyConstrainedSlotInsteadOfShiftingWildcardWindows() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let leftAny = WindowLayoutSlot(normalizedX: 0, normalizedY: 0, normalizedWidth: 0.33, normalizedHeight: 1)
        let middleChat = WindowLayoutSlot(
            normalizedX: 0.33,
            normalizedY: 0,
            normalizedWidth: 0.34,
            normalizedHeight: 1,
            allowedApps: ["Signal", "WhatsApp"]
        )
        let rightAny = WindowLayoutSlot(normalizedX: 0.67, normalizedY: 0, normalizedWidth: 0.33, normalizedHeight: 1)
        let template = makeTemplateOption(slots: [leftAny, middleChat, rightAny])
        let chrome = makeCandidate(windowID: 1, app: "Google Chrome", title: "Docs")
        let safari = makeCandidate(windowID: 2, app: "Safari", title: "News")

        let slotWindowIDs = RecentWindowTemplatePlanner.slotWindowIDs(
            for: template,
            candidates: [chrome, safari],
            displayFrame: displayFrame
        )

        XCTAssertEqual(slotWindowIDs, [1, nil, 2])
    }

    private func assertSpannedPlacements(windowCount count: Int, expectedSpannedIndexes: Set<Int>) {
        let grid = RecentWindowGridPlanner.dimensions(windowCount: count, displayAspectRatio: 1.6)
        let placements = RecentWindowGridPlanner.placements(windowCount: count, rows: grid.rows, cols: grid.cols)

        for index in placements.indices {
            let expectedSpan = expectedSpannedIndexes.contains(index) ? 2 : 1
            XCTAssertEqual(placements[index].rowSpan, expectedSpan, "row span for index \(index) with \(count) windows")
        }
    }

    private func makeCandidate(
        windowID: Int = 1,
        app: String,
        title: String,
        frame: CGRect = .zero,
        frontToBackOrder: Int = 0
    ) -> RecentWindowTilerCandidate {
        RecentWindowTilerCandidate(
            windowID: windowID,
            pid: 100,
            app: app,
            title: title,
            focused: false,
            floating: true,
            canAutoTile: true,
            canFloatingGrid: true,
            frame: frame,
            frontToBackOrder: frontToBackOrder
        )
    }

    private func makeTemplateOption(slots: [WindowLayoutSlot]) -> RecentWindowTilerTemplateOption {
        RecentWindowTilerTemplateOption(
            id: UUID(),
            name: "Two Up",
            slots: slots,
            displayShapeKey: DisplayShapeKey(aspectRatio: 1.5)
        )
    }
}
#endif
