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

    // MARK: - Islands

    func testMenusAndIconsBecomeTwoIslandsThatReachTheBarEdges() {
        let slots = [
            SystemBarSlot(kind: .menu(index: 0), x: 10, width: 34),
            SystemBarSlot(kind: .menu(index: 1), x: 44, width: 79),
            SystemBarSlot(kind: .icon(index: 0), x: 3600, width: 24),
            SystemBarSlot(kind: .icon(index: 1), x: 3630, width: 190),
        ]
        let islands = SystemBarLayoutPlanner.islands(for: slots, barWidth: 3840)
        XCTAssertEqual(islands, [0...129, 3594...3840])
    }

    func testIconGroupsCloseTogetherShareAnIslandAndDistantOnesDoNot() {
        let slots = [
            SystemBarSlot(kind: .icon(index: 0), x: 1000, width: 24),
            SystemBarSlot(kind: .icon(index: 1), x: 1040, width: 24),
            SystemBarSlot(kind: .icon(index: 2), x: 1500, width: 24),
        ]
        let islands = SystemBarLayoutPlanner.islands(for: slots, barWidth: 3840)
        XCTAssertEqual(islands, [994...1070, 1494...1530])
    }

    func testEmptyBarHasNoIslands() {
        XCTAssertTrue(SystemBarLayoutPlanner.islands(for: [], barWidth: 3840).isEmpty)
    }

    // MARK: - Icon row (every display's icons)

    private func sightings(_ pairs: (String, CGFloat)...) -> [SystemBarIconRow.Sighting] {
        pairs.map { SystemBarIconRow.Sighting(bar: $0.0, minX: $0.1) }
    }

    func testIconRowCopiesTheBarThatDrawsTheMostIcons() {
        // The laptop draws a, camera, b, c, d; the Samsung draws only d and b in its own order,
        // plus its own system icons.
        let row = SystemBarIconRow.order(
            icons: [
                ("a", sightings(("L", 100)), false),
                ("camera", sightings(("S", 2800), ("L", 120)), true),
                ("b", sightings(("L", 140), ("S", 3000)), false),
                ("c", sightings(("L", 180)), false),
                ("d", sightings(("L", 220), ("S", 2950)), false),
                ("clock", sightings(("S", 3100)), true),
                ("wifi", sightings(("S", 3050)), true),
            ],
            previousReference: nil
        )
        XCTAssertEqual(row.reference, "L")
        XCTAssertEqual(row.order, ["a", "camera", "b", "c", "d", "wifi", "clock"], "each icon once, where the copied bar draws it")
    }

    func testIconRowKeepsItsBarUnlessAnotherClearlyDrawsMore() {
        let icons: [(key: String, sightings: [SystemBarIconRow.Sighting], isSystem: Bool)] = [
            ("a", sightings(("L", 100), ("S", 900)), false),
            ("b", sightings(("L", 140), ("S", 800)), false),
            ("c", sightings(("S", 700)), false),
        ]
        let kept = SystemBarIconRow.order(icons: icons, previousReference: "L")
        XCTAssertEqual(kept.reference, "L")
        XCTAssertEqual(kept.order, ["c", "a", "b"], "an icon the copied bar does not draw goes at the left")
        let fresh = SystemBarIconRow.order(icons: icons, previousReference: nil)
        XCTAssertEqual(fresh.reference, "S")
    }

    func testIconRowKeepsTheSlotOfIconsThatMoveToAnotherDisplay() {
        // The laptop drew everything; focus moved to the Samsung and macOS now draws "t" and the
        // camera only there, and the laptop's clock is no longer found.
        let row = SystemBarIconRow.order(
            icons: [
                ("a", sightings(("L", 100)), false),
                ("camera", sightings(("S", 2800)), true),
                ("t", sightings(("S", 2870)), false),
                ("b", sightings(("L", 160)), false),
                ("c", sightings(("L", 200)), false),
                ("clock", sightings(("S", 3100)), true),
                ("new", sightings(("S", 2900)), false),
            ],
            previousReference: "L",
            previousOrder: ["a", "camera", "t", "b", "c", "clock"]
        )
        XCTAssertEqual(row.reference, "L")
        XCTAssertEqual(row.order, ["new", "a", "camera", "t", "b", "c", "clock"], "known icons stay put; a new one starts at the left")
    }

    func testIconRowGivesAnIconThatVanishedForAWhileItsSlotBack() {
        // The system icons disappear while the screen is locked; "quit" belongs to an app that quit.
        let memory = SystemBarIconRow.remembered(
            order: ["a", "t", "b"],
            previous: ["a", "camera", "t", "b", "quit", "clock"],
            keep: { $0 != "quit" }
        )
        XCTAssertEqual(memory, ["a", "camera", "t", "b", "clock"])
        // After the unlock the camera is drawn only on the Samsung, which is not the copied bar.
        let row = SystemBarIconRow.order(
            icons: [
                ("a", sightings(("L", 100)), false),
                ("camera", sightings(("S", 2800)), true),
                ("t", sightings(("L", 130)), false),
                ("b", sightings(("L", 160)), false),
                ("clock", sightings(("S", 3100)), true),
            ],
            previousReference: "L",
            previousOrder: memory
        )
        XCTAssertEqual(row.order, ["a", "camera", "t", "b", "clock"])
    }

    func testIconRowGapsKeepTheirLastMeasurementWhenNeighboursAreApart() {
        let gaps = SystemBarIconRow.learnedGaps(
            order: ["a", "t", "b", "c"],
            frames: [
                "a": ["L": CGRect(x: 100, y: 0, width: 24, height: 24)],
                "t": ["S": CGRect(x: 2870, y: 0, width: 36, height: 24)],
                "b": ["L": CGRect(x: 160, y: 0, width: 24, height: 24)],
                "c": ["L": CGRect(x: 190, y: 0, width: 24, height: 24)],
            ],
            previous: ["a": 9, "t": 7, "b": 3, "gone": 5]
        )
        XCTAssertEqual(gaps["a"], 9, "a and t are not drawn on one bar now")
        XCTAssertEqual(gaps["t"], 7)
        XCTAssertEqual(gaps["b"], 6, "measured: b and c sit next to each other on the laptop")
        XCTAssertNil(gaps["gone"])
    }

    func testIconRowPacksFromTheRightWithRealGaps() {
        let offsets = SystemBarIconRow.packedRightOffsets(
            order: ["a", "b", "clock"],
            widths: ["a": 24, "b": 36, "clock": 130],
            trailingGaps: ["a": 6, "b": 16],
            trailingInset: 20
        )
        XCTAssertEqual(offsets["clock"], 20)
        XCTAssertEqual(offsets["b"], 20 + 130 + 16)
        XCTAssertEqual(offsets["a"], 20 + 130 + 16 + 36 + 6)
    }

    func testCaptureRetriesQuicklyAfterAReconnectThenBacksOff() {
        XCTAssertEqual(SystemBarCapturePolicy.retryDelay(afterFailures: 1), 2)
        XCTAssertEqual(SystemBarCapturePolicy.retryDelay(afterFailures: 2), 10)
        XCTAssertEqual(SystemBarCapturePolicy.retryDelay(afterFailures: 7), 30)
    }

    // MARK: - Remembered icons

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func sticky(_ offset: CGFloat, _ width: CGFloat = 24, missing: Date? = nil) -> SystemBarStickyIcon {
        SystemBarStickyIcon(rightOffset: offset, width: width, missingSince: missing)
    }

    func testActiveBarDropsIconsItStoppedDrawingAfterTheGrace() {
        // TraceBar was remembered at offset 300; the active bar now draws Raycast there instead.
        let remembered = ["trace": sticky(300, 86), "wifi": sticky(100)]
        let drawn: [String: (rightOffset: CGFloat, width: CGFloat)] = ["wifi": (100, 24), "raycast": (310, 24)]

        let first = SystemBarStickyIconPolicy.update(remembered, drawn: drawn, ownBarIsActive: true, now: t0)
        XCTAssertNotNil(first["trace"], "kept during the grace in case the bar is still redrawing")
        XCTAssertNil(SystemBarStickyIconPolicy.shown(first)["trace"], "never drawn on top of an icon the bar shows now")

        let later = SystemBarStickyIconPolicy.update(first, drawn: drawn, ownBarIsActive: true, now: t0.addingTimeInterval(7))
        XCTAssertEqual(Set(later.keys), ["wifi", "raycast"])
    }

    func testInactiveBarKeepsTheLastActiveSetAndPlaces() {
        let remembered = ["a": sticky(100), "b": sticky(140), "c": sticky(180)]
        // While another display is active, macOS draws only one icon here, shifted.
        let drawn: [String: (rightOffset: CGFloat, width: CGFloat)] = ["c": (120, 24)]
        let next = SystemBarStickyIconPolicy.update(remembered, drawn: drawn, ownBarIsActive: false, now: t0)
        XCTAssertEqual(next, remembered)
    }

    func testInactiveBarAddsANewIconOnlyWhereItFits() {
        let remembered = ["a": sticky(100), "b": sticky(140)]
        let drawn: [String: (rightOffset: CGFloat, width: CGFloat)] = ["new": (110, 24), "far": (400, 24)]
        let next = SystemBarStickyIconPolicy.update(remembered, drawn: drawn, ownBarIsActive: false, now: t0)
        XCTAssertNil(next["new"])
        XCTAssertEqual(next["far"], sticky(400))
    }

    func testIconsNotYetRedrawnAfterFocusReturnsStayVisible() {
        let remembered = ["a": sticky(100), "b": sticky(140)]
        let drawn: [String: (rightOffset: CGFloat, width: CGFloat)] = ["a": (100, 24)]
        let next = SystemBarStickyIconPolicy.update(remembered, drawn: drawn, ownBarIsActive: true, now: t0)
        XCTAssertEqual(next["b"]?.missingSince, t0)
        XCTAssertNotNil(SystemBarStickyIconPolicy.shown(next)["b"])
        let redrawn = SystemBarStickyIconPolicy.update(next, drawn: ["a": (100, 24), "b": (140, 24)], ownBarIsActive: true, now: t0.addingTimeInterval(1))
        XCTAssertNil(redrawn["b"]?.missingSince)
    }

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

    // MARK: - Icon row state and background look

    private func rowItem(_ name: String, pid: Int32 = 42, bar: CGRect, x: CGFloat, width: CGFloat = 24, system: Bool = false) -> SystemBarStatusItem {
        var item = SystemBarStatusItem(
            id: name,
            pid: pid,
            bundleIdentifier: "com.example.\(name)",
            appName: name,
            identifier: system ? "com.apple.menuextra.\(name)" : name,
            title: "",
            descriptionText: "",
            value: "",
            frame: CGRect(x: x, y: bar.minY + 4, width: width, height: 22),
            menuBarFrame: bar
        )
        item.stableKey = "\(pid):\(name)"
        item.reportedMenuBarFrame = bar
        item.reportedFrame = item.frame
        return item
    }

    func testIconRowStateKeepsEveryPlaceWhenFocusMovesIconsToAnotherDisplay() {
        let laptop = CGRect(x: 0, y: 0, width: 2000, height: 30)
        let samsung = CGRect(x: -600, y: -2160, width: 3840, height: 30)
        var row = SystemBarIconRowState()
        func places() -> [String: CGFloat] {
            Dictionary(uniqueKeysWithValues: row.layout([], isShown: { _ in true }).map { ($0.item.appName, $0.metric.rightOffset) })
        }
        row.learn(from: [
            rowItem("a", bar: laptop, x: 1000), rowItem("t", bar: laptop, x: 1030),
            rowItem("b", bar: laptop, x: 1066), rowItem("clock", bar: laptop, x: 1900, width: 80, system: true),
        ])
        let laptopActive = row.layout([
            rowItem("a", bar: laptop, x: 1000), rowItem("t", bar: laptop, x: 1030),
            rowItem("b", bar: laptop, x: 1066), rowItem("clock", bar: laptop, x: 1900, width: 80, system: true),
        ], isShown: { _ in true }).map { "\($0.item.appName)@\($0.metric.rightOffset)" }
        // Focus moves to the Samsung: macOS now draws "t" and the clock only there.
        let moved = [
            rowItem("a", bar: laptop, x: 1000), rowItem("t", bar: samsung, x: 2900),
            rowItem("b", bar: laptop, x: 1066), rowItem("clock", bar: samsung, x: 3100, width: 80, system: true),
        ]
        row.learn(from: moved)
        XCTAssertEqual(row.order, ["com.example.a|a", "com.example.t|t", "com.example.b|b", "com.example.clock|clock"])
        XCTAssertEqual(row.layout(moved, isShown: { _ in true }).map { "\($0.item.appName)@\($0.metric.rightOffset)" }, laptopActive)
        XCTAssertTrue(places().isEmpty, "only icons present now are laid out")
    }

    func testIconRowStateKeepsSlotsAcrossARestartAndAnAppRelaunch() throws {
        let laptop = CGRect(x: 0, y: 0, width: 2000, height: 30)
        let samsung = CGRect(x: -600, y: -2160, width: 3840, height: 30)
        var row = SystemBarIconRowState()
        let start = Date()
        row.learn(from: [
            rowItem("a", bar: laptop, x: 1000), rowItem("t", bar: laptop, x: 1030), rowItem("b", bar: laptop, x: 1066),
        ], now: start)
        let saved = try JSONDecoder().decode(
            SystemBarIconRowState.Snapshot.self,
            from: try JSONEncoder().encode(row.snapshot)
        )

        // TilePilot restarts; "t" relaunched with a new process and macOS draws it on the Samsung.
        var restarted = SystemBarIconRowState(snapshot: saved)
        restarted.learn(from: [
            rowItem("a", bar: laptop, x: 1000), rowItem("t", pid: 99, bar: samsung, x: 2900), rowItem("b", bar: laptop, x: 1066),
        ], now: start.addingTimeInterval(60))
        XCTAssertEqual(restarted.order, ["com.example.a|a", "com.example.t|t", "com.example.b|b"])

        // An icon not seen for more than 30 days is forgotten.
        restarted.learn(from: [rowItem("a", bar: laptop, x: 1000)], now: start.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(restarted.memory, ["com.example.a|a", "com.example.t|t", "com.example.b|b"])
        restarted.learn(from: [rowItem("a", bar: laptop, x: 1000)], now: start.addingTimeInterval(31 * 86_400))
        XCTAssertEqual(restarted.memory, ["com.example.a|a"])
    }

    private func solidImage(_ gray: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()!
    }

    func testBackgroundLookIgnoresTheFadeOfASwitchingBar() {
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let start = Date()
        var look = SystemBarBackgroundLook()
        look.update(sample: solidImage(0), now: start)
        XCTAssertEqual(look.current?.isDark, true)
        // macOS fades the bar to gray for a moment while focus switches displays.
        look.update(sample: solidImage(0.5), now: start.addingTimeInterval(0.2))
        look.update(sample: solidImage(0), now: start.addingTimeInterval(0.6))
        look.update(sample: nil, now: start.addingTimeInterval(3))
        XCTAssertTrue(SystemBarBackgroundLook.sameLook(look.current?.color, black))
        // A color that holds is adopted.
        look.update(sample: solidImage(0.5), now: start.addingTimeInterval(4))
        look.update(sample: nil, now: start.addingTimeInterval(4.5))
        XCTAssertTrue(SystemBarBackgroundLook.sameLook(look.current?.color, black))
        look.update(sample: nil, now: start.addingTimeInterval(5.6))
        XCTAssertFalse(SystemBarBackgroundLook.sameLook(look.current?.color, black))
        XCTAssertEqual(look.current?.isDark, false)
    }

    // MARK: - Layout signature

    /// A bar stretch with white blocks (icons) on a dark background, at `scale` pixels per point.
    private func barImage(pointsWide: Int, scale: Int = 1, blocks: [ClosedRange<Int>], gray: [ClosedRange<Int>] = []) -> CGImage {
        let context = CGContext(
            data: nil, width: pointsWide * scale, height: 30 * scale, bitsPerComponent: 8, bytesPerRow: pointsWide * scale * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pointsWide, height: 30))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        for block in blocks {
            context.fill(CGRect(x: block.lowerBound, y: 8, width: block.count, height: 14))
        }
        context.setFillColor(CGColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1))
        for block in gray {
            context.fill(CGRect(x: block.lowerBound, y: 12, width: block.count, height: 6))
        }
        return context.makeImage()!
    }

    private func signature(_ blocks: [ClosedRange<Int>], gray: [ClosedRange<Int>] = [], scale: Int = 2) -> SystemBarLayoutSignature {
        SystemBarLayoutSignature.measure(barImage(pointsWide: 300, scale: scale, blocks: blocks, gray: gray), originX: 1000, pointsWide: 300)!
    }

    func testLayoutSignatureFindsIconsAndJoinsTheLettersOfATitle() {
        // The last two blocks are letters of one title, 2 pt apart.
        let found = signature([100...123, 130...153, 160...175, 178...190])
        XCTAssertEqual(found.spans, [1100...1124, 1130...1154, 1160...1191])
        XCTAssertEqual(signature([100...123, 130...153, 160...175, 178...190], scale: 1), found)
    }

    func testLayoutSignatureChangesOnlyWhenIconsMoveAppearOrDisappear() {
        let base = signature([100...123, 130...153, 160...190])
        XCTAssertFalse(signature([100...123, 130...153, 160...190], gray: [135...140]).differs(from: base), "a graph or digits changed inside an icon")
        XCTAssertFalse(signature([101...123, 130...153, 160...190]).differs(from: base), "a 1 pt wobble")
        XCTAssertTrue(signature([100...123, 130...160, 167...197]).differs(from: base), "an icon grew and pushed its neighbour")
        XCTAssertTrue(signature([60...80, 100...123, 130...153, 160...190]).differs(from: base), "a new icon")
        XCTAssertTrue(signature([100...123, 160...190]).differs(from: base), "an icon left")
    }

    // MARK: - Icon brightness

    /// A 24×22 icon: `ink` gray in the given columns over a `background` gray, as macOS would
    /// draw it at `fraction` of full brightness.
    private func iconImage(ink: CGFloat, background: CGFloat = 2, fraction: CGFloat = 1, columns: ClosedRange<Int> = 6...17) -> CGImage {
        let context = CGContext(
            data: nil, width: 24, height: 22, bitsPerComponent: 8, bytesPerRow: 24 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        let backgroundGray = background / 255
        context.setFillColor(CGColor(srgbRed: backgroundGray, green: backgroundGray, blue: backgroundGray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 22))
        let value = (background + fraction * (ink - background)) / 255
        context.setFillColor(CGColor(srgbRed: value, green: value, blue: value, alpha: 1))
        context.fill(CGRect(x: columns.lowerBound, y: 5, width: columns.count, height: 12))
        return context.makeImage()!
    }

    private func maxGray(_ image: CGImage) -> Int {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        return (0..<(image.width * image.height)).map { Int(bytes[$0 * 4 + 1]) }.max() ?? 0
    }

    func testIconBrightnessLearnsTheDimmingOfTemplateAndColorIcons() {
        XCTAssertEqual(SystemBarIconBrightness.learnFactor(bright: iconImage(ink: 230), dim: iconImage(ink: 230, fraction: 0.28)), 0.28)
        XCTAssertEqual(SystemBarIconBrightness.learnFactor(bright: iconImage(ink: 255), dim: iconImage(ink: 255, fraction: 0.6)), 0.6)
        XCTAssertEqual(SystemBarIconBrightness.learnFactor(bright: iconImage(ink: 230), dim: iconImage(ink: 230, fraction: 0.35)), 0.35, "the system's own icons")
        XCTAssertNil(SystemBarIconBrightness.learnFactor(bright: iconImage(ink: 230), dim: iconImage(ink: 230, fraction: 0.45)), "not a fraction macOS uses")
        XCTAssertNil(
            SystemBarIconBrightness.learnFactor(bright: iconImage(ink: 230, columns: 2...9), dim: iconImage(ink: 230, fraction: 0.28, columns: 14...21)),
            "the icon changed in between"
        )
    }

    func testIconBrightnessRestoresADimmedIconOnceItHasSeenItBright() {
        var brightness = SystemBarIconBrightness()
        let dim = iconImage(ink: 230, fraction: 0.28)
        XCTAssertNil(brightness.brightened(dim, key: "drive"), "unknown until seen bright")
        brightness.noteBright(iconImage(ink: 230), key: "drive")
        let restored = brightness.brightened(dim, key: "drive")
        XCTAssertEqual(maxGray(restored!), 230, accuracy: 3)
        XCTAssertEqual(brightness.factors["drive"], 0.28)
        // The fraction stays known for later copies, after a restart too.
        var restarted = SystemBarIconBrightness(factors: brightness.factors)
        XCTAssertEqual(maxGray(restarted.brightened(iconImage(ink: 230, fraction: 0.28, columns: 3...10), key: "drive")!), 230, accuracy: 3)
    }
}
#endif
