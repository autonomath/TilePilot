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
}
#endif
