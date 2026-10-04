#if canImport(XCTest)
import AppKit
import XCTest
@testable import TilePilot

final class DesktopScrubModelsTests: XCTestCase {
    func testLoadFromUserDefaultsFallsBackToDefaultSelectionWhenTooFewKeysProvided() {
        let loaded = DesktopScrubModifier.loadFromUserDefaults(rawValues: ["option"])

        XCTAssertEqual(loaded, DesktopScrubModifier.defaultSelection)
    }

    func testNormalizePreservesCanonicalModifierOrder() {
        let normalized = DesktopScrubModifier.normalize([.command, .shift, .option])

        XCTAssertEqual(normalized, [.shift, .option, .command])
    }

    func testFlagsRoundTripBackToModifiers() {
        let modifiers: [DesktopScrubModifier] = [.shift, .control, .option]
        let flags = DesktopScrubModifier.flags(for: modifiers)

        XCTAssertEqual(DesktopScrubModifier.from(flags: flags), modifiers)
    }

    func testCharacterKeyParsesLettersAndDigitsFromText() {
        XCTAssertEqual(DesktopScrubCharacterKey.from(eventCharacters: "a"), .a)
        XCTAssertEqual(DesktopScrubCharacterKey.from(eventCharacters: "A"), .a)
        XCTAssertEqual(DesktopScrubCharacterKey.from(eventCharacters: "4"), .four)
        XCTAssertNil(DesktopScrubCharacterKey.from(eventCharacters: "ab"))
    }

    func testCharacterKeyParsesLettersAndDigitsFromKeyCodes() {
        XCTAssertEqual(DesktopScrubCharacterKey.from(keyCode: 0), .a)
        XCTAssertEqual(DesktopScrubCharacterKey.from(keyCode: 18), .one)
        XCTAssertEqual(DesktopScrubCharacterKey.from(keyCode: 29), .zero)
        XCTAssertNil(DesktopScrubCharacterKey.from(keyCode: 53))
    }
}
#endif
