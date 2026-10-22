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
        XCTAssertTrue(body.contains("shift + alt - v : yabai -m space --layout stack"))
        XCTAssertTrue(body.contains("shift + alt - 1 : yabai -m window --space 1; yabai -m space --focus 1"))
    }

    func testConfigServiceUsesReleaseShortcutDefaults() {
        XCTAssertEqual(
            ConfigService().defaultManagedSectionBody(),
            ReleaseDefaultsService().currentProfile().configState.managedSkhdSectionBody
        )
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
