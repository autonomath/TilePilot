#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import TilePilot

final class SystemBarModelsTests: XCTestCase {
    private func item(
        _ title: String,
        enabled: Bool = true,
        command: String = "",
        modifiers raw: Int? = 0,
        glyph: Int = 0,
        submenu: Bool = false,
        mark: String = ""
    ) -> MirroredMenuItem {
        MirroredMenuItem(
            id: UUID().uuidString,
            title: title,
            isEnabled: enabled,
            hasSubmenu: submenu,
            markCharacter: mark,
            commandCharacter: command,
            commandGlyph: glyph,
            modifiers: MirroredMenuModifiers(axModifiers: raw, hasCommandCharacter: !command.isEmpty || glyph > 0)
        )
    }

    // MARK: - Modifiers

    func testModifierMaskDecodesCommandShiftOptionControlAndFunction() {
        XCTAssertEqual(
            MirroredMenuModifiers(axModifiers: 0, hasCommandCharacter: true),
            MirroredMenuModifiers(command: true, shift: false, option: false, control: false, function: false)
        )
        XCTAssertEqual(
            MirroredMenuModifiers(axModifiers: 1 | 2 | 4, hasCommandCharacter: true),
            MirroredMenuModifiers(command: true, shift: true, option: true, control: true, function: false)
        )
        // Fill is Fn + Control + F: mask 28 means no Command, Control, and Fn.
        XCTAssertEqual(
            MirroredMenuModifiers(axModifiers: 28, hasCommandCharacter: true),
            MirroredMenuModifiers(command: false, shift: false, option: false, control: true, function: true)
        )
    }

    func testModifierMaskWithoutCharacterNeverClaimsCommand() {
        // "Zoom" reports mask 8 and no character; "Bring All to Front" the same.
        XCTAssertEqual(MirroredMenuModifiers(axModifiers: 8, hasCommandCharacter: false), .none)
        XCTAssertEqual(MirroredMenuModifiers(axModifiers: 0, hasCommandCharacter: false), .none)
        XCTAssertEqual(MirroredMenuModifiers(axModifiers: nil, hasCommandCharacter: true), .none)
    }

    // MARK: - Separators and alternates

    func testSeparatorIsDisabledUntitledAndChildless() {
        XCTAssertTrue(item("", enabled: false).isSeparator)
        XCTAssertFalse(item("", enabled: true).isSeparator)
        XCTAssertFalse(item("Open", enabled: false).isSeparator)
        XCTAssertFalse(item("", enabled: false, submenu: true).isSeparator)
    }

    func testAlternatesFollowTheirPrimaryWithOptionAdded() {
        let marked = MirroredMenuItem.markingAlternates([
            item("Close", command: "W", modifiers: 0),
            item("Close All", command: "W", modifiers: 2),
            item("Minimize", command: "M", modifiers: 0),
            item("Zoom", modifiers: 8),
            item("Zoom All", modifiers: 10),
            item("", enabled: false),
            item("Bring All to Front", modifiers: 8),
            item("Arrange in Front", modifiers: 10),
        ])
        XCTAssertEqual(marked.map(\.isAlternate), [false, true, false, false, true, false, false, true])
    }

    func testAlternateDetectionIgnoresUnrelatedNeighbours() {
        let marked = MirroredMenuItem.markingAlternates([
            item("New Tab", command: "T", modifiers: 0),
            item("New Window", command: "N", modifiers: 0),
            item("New Incognito Window", command: "N", modifiers: 1),
            item("Reopen Closed Tab", command: "T", modifiers: 1),
        ])
        XCTAssertEqual(marked.map(\.isAlternate), [false, false, false, false])
    }

    // MARK: - Action names

    func testCustomActionLabelComesFromTheNameLine() {
        XCTAssertEqual(AccessibilityActionName.label("Name:Show Details\nTarget:0x0\nSelector:(null)"), "Show Details")
        XCTAssertEqual(AccessibilityActionName.label("Name:Remove from Menu Bar"), "Remove from Menu Bar")
        XCTAssertEqual(AccessibilityActionName.label("AXPress"), "AXPress")
        XCTAssertTrue(AccessibilityActionName.isCustomAction("Name:Clear All\nTarget:0x0"))
        XCTAssertFalse(AccessibilityActionName.isCustomAction("AXShowMenu"))
    }

    // MARK: - Status items

    private func statusItem(identifier: String, frame: CGRect, menuBar: CGRect, title: String = "", desc: String = "", value: String = "") -> SystemBarStatusItem {
        SystemBarStatusItem(
            id: UUID().uuidString,
            pid: 42,
            bundleIdentifier: "com.example.app",
            appName: "Example",
            identifier: identifier,
            title: title,
            descriptionText: desc,
            value: value,
            frame: frame,
            menuBarFrame: menuBar
        )
    }

    func testStatusItemOffsetsAreMeasuredFromItsOwnMenuBar() {
        let samsungBar = CGRect(x: -687, y: -2160, width: 3840, height: 30)
        let clock = statusItem(identifier: "com.apple.menuextra.clock", frame: CGRect(x: 2995, y: -2156, width: 138, height: 22), menuBar: samsungBar, desc: "Clock", value: "Wed Oct 21  10:32 AM")
        XCTAssertEqual(clock.rightOffset, 20)
        XCTAssertEqual(clock.menuBarLocalY, 4)
        XCTAssertTrue(clock.isSystemExtra)
        XCTAssertTrue(clock.isClock)
        XCTAssertEqual(clock.tooltip, "Clock: Wed Oct 21  10:32 AM")

        let builtInBar = CGRect(x: 0, y: 0, width: 2294, height: 30)
        let thirdParty = statusItem(identifier: "", frame: CGRect(x: 1817, y: 2, width: 40, height: 24), menuBar: builtInBar)
        XCTAssertEqual(thirdParty.rightOffset, 437)
        XCTAssertEqual(thirdParty.menuBarLocalY, 2)
        XCTAssertFalse(thirdParty.isSystemExtra)
        XCTAssertNil(thirdParty.simplifiedSymbolName)
        XCTAssertEqual(thirdParty.tooltip, "Example")
    }

    func testSystemExtrasMapToSymbols() {
        let bar = CGRect(x: 0, y: 0, width: 2294, height: 30)
        let frame = CGRect(x: 100, y: 4, width: 22, height: 22)
        XCTAssertEqual(statusItem(identifier: "com.apple.menuextra.wifi", frame: frame, menuBar: bar).simplifiedSymbolName, "wifi")
        XCTAssertEqual(statusItem(identifier: "com.apple.menuextra.battery", frame: frame, menuBar: bar).simplifiedSymbolName, "battery.100")
        XCTAssertEqual(statusItem(identifier: "com.apple.menuextra.focusmode", frame: frame, menuBar: bar).simplifiedSymbolName, "moon.fill")
        XCTAssertEqual(statusItem(identifier: "com.apple.menuextra.controlcenter", frame: frame, menuBar: bar).simplifiedSymbolName, "switch.2")
        XCTAssertNil(statusItem(identifier: "com.apple.menuextra.clock", frame: frame, menuBar: bar).simplifiedSymbolName)
    }

    func testSimplifiedTitleKeepsReadingsAndDropsResourceNames() {
        let bar = CGRect(x: 0, y: 0, width: 2294, height: 30)
        let frame = CGRect(x: 100, y: 2, width: 40, height: 24)
        XCTAssertEqual(statusItem(identifier: "", frame: frame, menuBar: bar, title: "23%").simplifiedTitleText, "23%")
        XCTAssertEqual(statusItem(identifier: "", frame: frame, menuBar: bar, title: "72°").simplifiedTitleText, "72°")
        XCTAssertEqual(statusItem(identifier: "", frame: frame, menuBar: bar, title: "12:30").simplifiedTitleText, "12:30")
        XCTAssertEqual(statusItem(identifier: "", frame: frame, menuBar: bar, title: "CPU").simplifiedTitleText, "CPU")
        XCTAssertNil(statusItem(identifier: "", frame: frame, menuBar: bar, title: "menuBarIcon").simplifiedTitleText)
        XCTAssertNil(statusItem(identifier: "", frame: frame, menuBar: bar, title: "").simplifiedTitleText)
        XCTAssertNil(statusItem(identifier: "", frame: frame, menuBar: bar, title: "A very long status item title").simplifiedTitleText)
    }

    // MARK: - Layout planner

    private func slotX(_ plan: SystemBarLayoutPlan, _ kind: SystemBarSlot.Kind) -> CGFloat? {
        plan.slots.first { $0.kind == kind }?.x
    }

    func testPlannerKeepsRealSpacingAndRightAlignsIcons() {
        // Chrome's titles on the Samsung, then the Samsung's own icons (group 1000).
        let menus: [CGFloat] = [34, 72, 42, 44, 50, 88]
        let icons = [
            SystemBarIconMetric(width: 26, rightOffset: 174, group: 1_000), // Control Centre
            SystemBarIconMetric(width: 138, rightOffset: 20, group: 1_000), // Clock
            SystemBarIconMetric(width: 22, rightOffset: 216, group: 1_000), // Wi-Fi
        ]
        let plan = SystemBarLayoutPlanner.plan(barWidth: 2560, menuWidths: menus, icons: icons)
        XCTAssertFalse(plan.hasOverflow)
        XCTAssertEqual(slotX(plan, .menu(index: 0)), 10)
        XCTAssertEqual(slotX(plan, .menu(index: 1)), 44)
        XCTAssertEqual(slotX(plan, .menu(index: 5)), 10 + 34 + 72 + 42 + 44 + 50)
        XCTAssertEqual(slotX(plan, .icon(index: 1)), 2560 - 20 - 138)
        XCTAssertEqual(slotX(plan, .icon(index: 0)), 2560 - 174 - 26)
        XCTAssertEqual(slotX(plan, .icon(index: 2)), 2560 - 216 - 22)
        // Slots are ordered left to right.
        XCTAssertEqual(plan.slots.map(\.x), plan.slots.map(\.x).sorted())
    }

    func testPlannerPlacesOtherDisplaysIconsLeftOfTheOwnGroupWithAGap() {
        let own = [SystemBarIconMetric(width: 138, rightOffset: 20, group: 1_000)]
        let laptop = [
            SystemBarIconMetric(width: 24, rightOffset: 300, group: 0),
            SystemBarIconMetric(width: 40, rightOffset: 340, group: 0),
        ]
        let plan = SystemBarLayoutPlanner.plan(barWidth: 2560, menuWidths: [34], icons: own + laptop)
        let ownX = slotX(plan, .icon(index: 0))!
        let rightmostLaptopX = slotX(plan, .icon(index: 1))!
        let leftmostLaptopX = slotX(plan, .icon(index: 2))!
        XCTAssertEqual(ownX, 2560 - 20 - 138)
        XCTAssertEqual(rightmostLaptopX + 24, ownX - SystemBarLayoutPlanner.groupGap)
        // The laptop group keeps its own internal spacing: offsets 300 (24 wide) and 340 (40 wide)
        // leave 16 pt between the two icons.
        XCTAssertEqual(leftmostLaptopX + 40, rightmostLaptopX - 16)
        XCTAssertEqual(SystemBarLayoutPlanner.iconDisplayOrder(own + laptop), [2, 1, 0])
    }

    func testPlannerOverflowsLeftmostIconsFirst() {
        let menus: [CGFloat] = [34, 80, 42, 42, 50]
        let icons = (0..<10).map { index in
            SystemBarIconMetric(width: 30, rightOffset: CGFloat(20 + index * 30), group: 1_000)
        }
        // Menus need 258 pt; icons need 320 pt; a 480 pt bar cannot hold both plus the gap.
        let plan = SystemBarLayoutPlanner.plan(barWidth: 480, menuWidths: menus, icons: icons)
        XCTAssertTrue(plan.hasOverflow)
        XCTAssertTrue(plan.overflowMenuIndices.isEmpty)
        XCTAssertEqual(plan.overflowIconIndices.first, 9, "the leftmost icon (largest right offset) leaves first")
        XCTAssertNotNil(slotX(plan, .overflow))
        XCTAssertNotNil(slotX(plan, .icon(index: 0)), "the clock stays")
        XCTAssertEqual(plan.slots.filter { if case .menu = $0.kind { return true } else { return false } }.count, 5)
    }

    func testPlannerOverflowsRightmostMenusWhenIconsAreGone() {
        let menus: [CGFloat] = [34, 80, 42, 42, 50, 60, 70]
        let plan = SystemBarLayoutPlanner.plan(barWidth: 220, menuWidths: menus, icons: [])
        XCTAssertTrue(plan.hasOverflow)
        XCTAssertEqual(plan.overflowMenuIndices.first, 6)
        XCTAssertFalse(plan.overflowMenuIndices.contains(0), "the Apple menu never overflows")
        XCTAssertNotNil(slotX(plan, .menu(index: 0)))
        XCTAssertNotNil(slotX(plan, .overflow))
    }

    // MARK: - Configuration

    func testWorkAreaConfigurationDecodesMissingSystemBarFieldsWithDefaults() throws {
        let json = """
        {"displayName":"SAMSUNG","displayWidth":3840,"displayHeight":2160,"normalizedX":0.1,"normalizedY":0.2,"normalizedWidth":0.6,"normalizedHeight":0.6}
        """
        let configuration = try JSONDecoder().decode(WorkAreaConfiguration.self, from: Data(json.utf8))
        XCTAssertFalse(configuration.systemBarEnabled)
        XCTAssertFalse(configuration.notificationMirrorEnabled)
        XCTAssertTrue(configuration.panelMirrorEnabled)

        var updated = configuration
        updated.systemBarEnabled = true
        let data = try JSONEncoder().encode(updated)
        let decoded = try JSONDecoder().decode(WorkAreaConfiguration.self, from: data)
        XCTAssertTrue(decoded.systemBarEnabled)
    }
}
#endif
