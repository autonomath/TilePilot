#if canImport(XCTest)
import AppKit
import XCTest
@testable import TilePilot

final class ShortcutRecordingKeyTests: XCTestCase {
    func testFunctionKeysRecordAsSupportedSkhdLiterals() {
        XCTAssertEqual(combo(122, [.control, .function]), "ctrl - f1")
        XCTAssertEqual(combo(111, [.shift, .function]), "shift - f12")
        XCTAssertEqual(combo(90, [.function]), "f20")
    }

    func testNavigationKeysDoNotDuplicateImplicitFunctionModifier() {
        XCTAssertEqual(combo(123, [.command, .function]), "cmd - left")
        XCTAssertEqual(combo(117, [.control, .function]), "ctrl - delete")
        XCTAssertEqual(combo(115, [.function]), "home")
        XCTAssertEqual(combo(121, [.function]), "pagedown")
    }

    func testKeypadUsesPhysicalKeyCodeInsteadOfMainKeyboardCharacter() {
        XCTAssertEqual(combo(76, [.control], "\r"), "ctrl - 0x4C")
        XCTAssertEqual(combo(83, [.command], "1"), "cmd - 0x53")
    }

    func testNonUSLayoutUsesRecordedUnmodifiedCharacter() {
        // The physical US A key can be Q on the active keyboard layout.
        XCTAssertEqual(combo(0, [.control, .shift], "q"), "ctrl + shift - q")
        XCTAssertEqual(combo(12, [.option], "a"), "alt - a")
    }

    func testUnsupportedCharacterSyntaxFallsBackToPhysicalKeyCode() {
        XCTAssertEqual(combo(0, [.command], "é"), "cmd - 0x00")
        XCTAssertEqual(combo(10, [.control], "§"), "ctrl - 0x0A")
        XCTAssertEqual(combo(3, [.control], "#"), "ctrl - 0x03")
        XCTAssertEqual(combo(50, [.control], nil), "ctrl - 0x32")
    }

    func testPunctuationUsesUppercaseHexRequiredBySkhdGrammar() {
        XCTAssertEqual(combo(24, [.control], "="), "ctrl - 0x18")
        XCTAssertEqual(combo(27, [.control], "-"), "ctrl - 0x1B")
        XCTAssertEqual(combo(30, [.control], "]"), "ctrl - 0x1E")
        XCTAssertEqual(combo(33, [.control], "["), "ctrl - 0x21")
        XCTAssertEqual(combo(39, [.control], "'"), "ctrl - 0x27")
        XCTAssertEqual(combo(41, [.control], ";"), "ctrl - 0x29")
        XCTAssertEqual(combo(42, [.control], "\\"), "ctrl - 0x2A")
        XCTAssertEqual(combo(43, [.control], ","), "ctrl - 0x2B")
        XCTAssertEqual(combo(44, [.control], "/"), "ctrl - 0x2C")
        XCTAssertEqual(combo(47, [.control], "."), "ctrl - 0x2F")
        XCTAssertEqual(combo(50, [.control], "`"), "ctrl - 0x32")
    }

    func testOnlyUnmodifiedEscapeCancels() {
        XCTAssertTrue(ShortcutRecordingKey.cancelsRecording(keyCode: 53, modifiers: []))
        XCTAssertFalse(ShortcutRecordingKey.cancelsRecording(keyCode: 53, modifiers: [.command]))
        XCTAssertEqual(combo(53, [.command]), "cmd - escape")
    }

    func testModifierOnlyAndInvalidKeyCodesAreRejected() {
        XCTAssertNil(combo(55, [.command]))
        XCTAssertNil(combo(63, [.function]))
        XCTAssertNil(combo(UInt16.max, []))
    }

    func testExplicitFunctionModifierIsPreservedForOrdinaryKeys() {
        XCTAssertEqual(combo(0, [.function, .control], "a"), "ctrl + fn - a")
    }

    private func combo(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, _ characters: String? = nil) -> String? {
        ShortcutRecordingKey.combo(keyCode: keyCode, modifiers: modifiers, unmodifiedCharacters: characters)
    }
}
#endif
