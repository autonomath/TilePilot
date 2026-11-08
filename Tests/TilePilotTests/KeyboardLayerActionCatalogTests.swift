#if canImport(XCTest)
import AppKit
import XCTest
@testable import TilePilot

final class KeyboardLayerActionCatalogTests: XCTestCase {
    private let safari = KeyboardLayerApp(bundleID: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app")
    private let notes = KeyboardLayerApp(bundleID: "com.apple.Notes", name: "Notes", path: "/System/Applications/Notes.app")

    func testBuiltInIDsAreUniqueAndEachResolves() {
        let ids = KeyboardLayerActionCatalog.builtIns.map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            XCTAssertEqual(KeyboardLayerActionCatalog.builtIn(id: id)?.id, id)
        }
    }

    func testEveryCategoryHasRowsAndRowIDsAreUnique() {
        let items = sampleItems()

        for category in KeyboardLayerActionCategory.allCases {
            XCTAssertFalse(items.filter { $0.category == category }.isEmpty, category.title)
        }
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
    }

    func testSearchFindsActionsAppsAndShortcuts() {
        let items = sampleItems()
        func titles(_ query: String) -> [String] {
            KeyboardLayerActionCatalog.search(items, query: query).map(\.title)
        }

        XCTAssertTrue(titles("lock").contains("Lock Screen"))
        XCTAssertEqual(titles("left half"), ["Snap Left Half"])
        XCTAssertTrue(titles("notes").contains("Notes"))
        XCTAssertTrue(titles("alt - h").contains("Focus West"))
        XCTAssertTrue(titles("take a break").contains("Run “Take a Break”"))
    }

    func testARunningAppIsListedOnceUnderRunning() {
        let items = sampleItems()

        XCTAssertEqual(items.filter { $0.title == "Safari" }.map(\.section), ["Running"])
        XCTAssertEqual(items.filter { $0.title == "Notes" }.map(\.section), ["All Apps"])
    }

    func testRequirementsMatchWhatEachActionNeeds() {
        XCTAssertEqual(KeyboardLayerActionCatalog.builtIn(id: "window.desktop.3")?.requirement, .scriptingAddition)
        XCTAssertEqual(KeyboardLayerActionCatalog.builtIn(id: "window.swap.left")?.requirement, .yabai)
        XCTAssertEqual(KeyboardLayerActionCatalog.builtIn(id: "desktop.go.2")?.requirement, .yabai)
        XCTAssertEqual(KeyboardLayerActionCatalog.builtIn(id: "macos.lock")?.requirement, KeyboardLayerRequirement.none)

        // An unmet requirement keeps the row selectable, with a note.
        let items = sampleItems(unmet: [.scriptingAddition])
        XCTAssertEqual(items.first { $0.id == "window.desktop.3" }?.note, "Needs yabai’s scripting addition")
        XCTAssertNil(items.first { $0.id == "window.swap.left" }?.note)
    }

    func testSnapSlotsAndCenterLandInsideTheArea() {
        let area = CGRect(x: 100, y: 50, width: 2000, height: 1000)

        for builtIn in KeyboardLayerActionCatalog.builtIns {
            guard case .snap(let slot) = builtIn.work else { continue }
            let frame = WorkAreaGeometry.snapFrame(slot: slot, windowSize: CGSize(width: 3000, height: 400), area: area)
            XCTAssertTrue(WorkAreaGeometry.isContained(frame, in: area, tolerance: 0), builtIn.id)
            XCTAssertGreaterThan(frame.width * frame.height, 0, builtIn.id)
        }
        XCTAssertEqual(
            WorkAreaGeometry.snapFrame(slot: CGRect(x: 0, y: 0, width: 0.5, height: 1), windowSize: .zero, area: area),
            CGRect(x: 100, y: 50, width: 1000, height: 1000)
        )
        XCTAssertEqual(
            WorkAreaGeometry.snapFrame(slot: nil, windowSize: CGSize(width: 800, height: 600), area: area),
            CGRect(x: 700, y: 250, width: 800, height: 600)
        )
    }

    func testAppScannerSortsDedupesAndSkipsAppsInsideApps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TilePilotAppScan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(root.appendingPathComponent("Zebra.app"), bundleID: "test.zebra")
        try makeApp(root.appendingPathComponent("Copy/Zebra.app"), bundleID: "test.zebra")
        try makeApp(root.appendingPathComponent("Zebra.app/Contents/Helpers/Inner.app"), bundleID: "test.inner")
        try makeApp(root.appendingPathComponent("Utilities/Alpha.app"), bundleID: "test.alpha")
        try makeApp(root.appendingPathComponent("A/B/Deep.app"), bundleID: "test.deep")
        try makeApp(root.appendingPathComponent("A/B/C/TooDeep.app"), bundleID: "test.too-deep")

        let apps = KeyboardLayerAppScanner.installedApps(in: [root])

        XCTAssertEqual(apps.map(\.name), ["Alpha", "Deep", "Zebra"])
        XCTAssertEqual(apps.map(\.bundleID), ["test.alpha", "test.deep", "test.zebra"])
    }

    func testDraftsSaveWhatWasTypedAndEmptyMeansNoAction() {
        XCTAssertNil(KeyboardLayerEditorDraft(setting: .text, text: " \n ").action)
        XCTAssertEqual(KeyboardLayerEditorDraft(setting: .text, text: "Hi\nthere\n").action, .typeText("Hi\nthere\n"))
        XCTAssertEqual(KeyboardLayerEditorDraft(setting: .url, text: " example.com ").action, .openURL("example.com"))
        XCTAssertEqual(KeyboardLayerEditorDraft(setting: .command, text: "ls").action, .runCommand(command: "ls", title: nil))
        XCTAssertEqual(KeyboardLayerEditorDraft(.typeText("Hi")), KeyboardLayerEditorDraft(setting: .text, text: "Hi"))
        // skhd entries are list rows, not typed commands.
        XCTAssertNil(KeyboardLayerEditorDraft(.runCommand(command: "ls", title: "From skhd")))
        XCTAssertEqual(KeyboardLayerActionCatalog.normalizedURL("example.com"), "https://example.com")
        XCTAssertEqual(KeyboardLayerActionCatalog.preview("First line\nSecond"), "First line…")
    }

    // MARK: Helpers

    private func sampleItems(unmet: Set<KeyboardLayerRequirement> = []) -> [KeyboardLayerPickerItem] {
        KeyboardLayerActionCatalog.items(
            features: [
                .init(id: "action.focus-left", title: "Focus Left", group: .focus),
                .init(id: "app.open-megamap", title: "Open MegaMap", group: .other),
                .init(id: "layout.balance", title: "Balance", group: .tilingLayout),
            ],
            runningApps: [safari],
            installedApps: [notes, safari],
            appleShortcuts: ["Take a Break"],
            skhdShortcuts: [.init(title: "Focus West", combo: "alt - h", command: "yabai -m window --focus west")],
            appExists: { _ in true },
            unmetNote: { requirement in
                guard unmet.contains(requirement) else { return nil }
                return requirement == .scriptingAddition ? "Needs yabai’s scripting addition" : "Needs yabai running"
            }
        )
    }

    private func makeApp(_ url: URL, bundleID: String) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
#endif
