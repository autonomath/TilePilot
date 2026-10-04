#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class BehaviorPolicySupportTests: XCTestCase {
    func testCanonicalizeAppRuleListDeduplicatesByNormalizedKey() {
        let values = [
            " Telegram ",
            "telegram",
            "Activity Monitor",
        ]

        let canonical = canonicalizeAppRuleList(values)

        XCTAssertEqual(canonical, ["Activity Monitor", "Telegram"])
    }

    func testAddingAndRemovingAppNameUsesNormalizedMatching() {
        let values = ["Spotify", "Activity Monitor"]

        let added = addingAppName("  spotify  ", to: values)
        XCTAssertEqual(added, ["Activity Monitor", "Spotify"])

        let removed = removeAppName("ACTIVITY MONITOR", from: added)
        XCTAssertEqual(removed, ["Spotify"])
    }

    func testParseExternalYabaiAppBehaviorsIgnoresManagedSectionAndParsesUserRules() {
        let content = """
        yabai -m rule --add app="^Telegram$" manage=off
        # >>> YABAI_COACH YABAI CONFIG BEGIN
        yabai -m rule --add app="^Spotify$" manage=on
        # <<< YABAI_COACH YABAI CONFIG END
        yabai -m rule --add app="^(Calendar|Sonos)$" manage=on
        """

        let parsed = parseExternalYabaiAppBehaviors(
            from: content,
            beginMarker: "# >>> YABAI_COACH YABAI CONFIG BEGIN",
            endMarker: "# <<< YABAI_COACH YABAI CONFIG END"
        )

        XCTAssertEqual(parsed[normalizedAppRuleKey("Telegram")], .neverTile)
        XCTAssertEqual(parsed[normalizedAppRuleKey("Calendar")], .alwaysTile)
        XCTAssertEqual(parsed[normalizedAppRuleKey("Sonos")], .alwaysTile)
        XCTAssertNil(parsed[normalizedAppRuleKey("Spotify")])
    }
}
#endif
