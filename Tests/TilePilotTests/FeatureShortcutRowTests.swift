#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class FeatureShortcutRowTests: XCTestCase {
    @MainActor
    func testRowShowsTheLineThatRecordingRewrites() {
        let model = AppModel()
        let bspAndBalance = entry("shift + alt - g", "yabai -m space --layout bsp; yabai -m space --balance", line: 37)
        XCTAssertEqual(model.featureDefinition(for: bspAndBalance)?.id, "screen.layout-bsp-balance")

        // The user's own line sits higher in skhdrc than the one TilePilot just recorded.
        let own = entry("shift + alt - t", "yabai -m space --layout bsp", line: 10)
        let recorded = entry("shift + cmd - p", "yabai -m space --layout bsp", line: 112, managedFeatureID: "screen.current-desktop-tiling-on")
        let rows = model.buildFeatureControlRows(from: [own, recorded].map(baseRow))
        XCTAssertEqual(rows.first { $0.featureID == "screen.current-desktop-tiling-on" }?.assignedCombo, "shift + cmd - p")
    }

    private func entry(_ combo: String, _ command: String, line: Int, managedFeatureID: String? = nil) -> ShortcutEntry {
        ShortcutEntry(id: UUID(), combo: combo, command: command, category: "Spaces", sourceLine: line,
                      sourceFile: "skhdrc", warning: nil, managedFeatureID: managedFeatureID)
    }

    private func baseRow(_ entry: ShortcutEntry) -> UnifiedControlRow {
        UnifiedControlRow(id: "shortcut-\(entry.stableKey)", group: .tilingLayout, title: entry.combo, description: "",
                          shortcutEntry: entry, actionID: nil, secondaryActionIDs: [], isExperimental: false,
                          disabledReason: nil, intentKey: entry.stableKey, featureID: nil)
    }
}
#endif
