#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class ReleaseDefaultsTests: XCTestCase {
    func testManagedSkhdDefaultsSeedShortcutFamilies() {
        let body = ReleaseDefaultsService().currentProfile().configState.managedSkhdSectionBody

        XCTAssertTrue(body.contains("alt - 1 : yabai -m space --focus 1"))
        XCTAssertTrue(body.contains("alt - 9 : yabai -m space --focus 9"))
        XCTAssertTrue(body.contains("alt - j : yabai -m window --focus west"))
        XCTAssertTrue(body.contains("shift + alt - j : yabai -m window --warp west"))
        XCTAssertTrue(body.contains("ctrl + alt - j : yabai -m window --resize left:-80:0"))
        XCTAssertTrue(body.contains("ctrl + shift + alt - j : yabai -m window --swap west"))
        XCTAssertTrue(body.contains("ctrl + shift + alt - s : yabai -m space --layout stack"))
        XCTAssertTrue(body.contains("shift + alt - 1 : yabai -m window --space 1; yabai -m space --focus 1"))
    }

    func testDefaultsBindEachKeyOnce() {
        let body = ReleaseDefaultsService().currentProfile().configState.managedSkhdSectionBody
        let combos = body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { ShortcutComboIdentity.normalized(String($0.split(separator: ":", maxSplits: 1)[0])) }
        XCTAssertEqual(Dictionary(grouping: combos, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted(), [])
    }

    @MainActor
    func testEveryMarkedDefaultIsAKnownFeature() {
        let body = ReleaseDefaultsService().currentProfile().configState.managedSkhdSectionBody
        let known = Set(AppModel().featureDefinitions.map(\.id.rawValue))
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let prefix = ShortcutEntry.managedFeatureMarkerPrefix
        for (index, line) in lines.enumerated() where line.hasPrefix(prefix) {
            let id = String(line.dropFirst(prefix.count))
            XCTAssertTrue(known.contains(id), id)
            XCTAssertTrue(lines[index + 1].contains(" : "), id)
        }
    }

    func testConfigServiceUsesReleaseShortcutDefaults() {
        XCTAssertEqual(
            ConfigService().defaultManagedSectionBody(),
            ReleaseDefaultsService().currentProfile().configState.managedSkhdSectionBody
        )
    }

    func testDefaultsUseAKeySkhdCanParse() {
        let body = ReleaseDefaultsService().currentProfile().configState.managedSkhdSectionBody
        XCTAssertTrue(body.contains("shift + alt - space : yabai -m window --toggle float"))
        XCTAssertEqual(ConfigService.repairedManagedSectionBody(body), body)
    }

    func testRepairReplacesTildeKeyOnly() {
        let body = """
        # ctrl - ~ : comment stays
        ctrl + shift + alt - ~ : yabai -m window --toggle float
        ctrl - d : ~/.config/yabai/scripts/a-b.sh ~ :x
        alt + cmd - a : /usr/bin/open -g "tilepilot://feature/app.open-megamap"
        """
        XCTAssertEqual(ConfigService.repairedManagedSectionBody(body), """
        # ctrl - ~ : comment stays
        ctrl + shift + alt - 0x32 : yabai -m window --toggle float
        ctrl - d : ~/.config/yabai/scripts/a-b.sh ~ :x
        alt + cmd - a : /usr/bin/open -g "tilepilot://feature/app.open-megamap"
        """)
    }

    func testReleaseDefaultsResetClearsWorkAreas() {
        XCTAssertEqual(ReleaseDefaultsService().currentProfile().userState.workAreas, [])
    }

    func testUserStateFromBeforeWorkAreasStillDecodes() throws {
        let profile = ReleaseDefaultsService().currentProfile()
        let encoded = try JSONEncoder().encode(profile.userState)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "workAreas")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ReleaseDefaultsUserState.self, from: legacy)
        XCTAssertEqual(decoded.workAreas, [])
        XCTAssertEqual(decoded.pinnedFeatureControlIDs, profile.userState.pinnedFeatureControlIDs)
    }
}
#endif
