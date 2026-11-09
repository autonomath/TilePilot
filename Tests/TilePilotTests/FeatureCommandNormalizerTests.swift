#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class FeatureCommandNormalizerTests: XCTestCase {
    func testNormalizeStripsEnvOpenAndCanonicalizesTilePilotURL() {
        let command = "  /usr/bin/env   /usr/bin/open   tilepilot:/feature/open-main-window  "

        let normalized = FeatureCommandNormalizer.normalize(command)

        XCTAssertEqual(normalized, "open tilepilot://feature/open-main-window")
    }

    func testNormalizeCollapsesWhitespaceWithoutChangingCommandMeaning() {
        let command = "ctrl   shift    option   "

        let normalized = FeatureCommandNormalizer.normalize(command)

        XCTAssertEqual(normalized, "ctrl shift option")
    }

    func testDesktopEquivalentReadsDefaultDesktopLinesAsYabai() {
        XCTAssertEqual(FeatureCommandNormalizer.desktopEquivalent(#"/usr/bin/open -g "tilepilot://desktop/3""#),
                       "yabai -m space --focus 3")
        XCTAssertEqual(FeatureCommandNormalizer.desktopEquivalent("yabai -m window --space 12 --focus"),
                       "yabai -m window --space 12; yabai -m space --focus 12")
        // With a target, --focus focuses that other window instead of following this one.
        let own = "yabai -m window --space 2 --focus 5"
        XCTAssertEqual(FeatureCommandNormalizer.desktopEquivalent(own), own)
        XCTAssertEqual(FeatureCommandNormalizer.desktopEquivalent("yabai -m space --focus 4"), "yabai -m space --focus 4")
    }
}
#endif
