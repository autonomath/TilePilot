#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class ShortcutComboIdentityTests: XCTestCase {
    func testModifierOrderDoesNotHideConflict() {
        XCTAssertEqual(identity("shift + alt - s"), identity("ALT+SHIFT-S"))
        XCTAssertEqual(identity("cmd + ctrl + shift + alt - s"), identity("ctrl + shift + alt + cmd - s"))
    }

    func testSkhdModifierAliasesMatchExpandedFlags() {
        XCTAssertEqual(identity("hyper - s"), identity("ctrl + shift + alt + cmd - s"))
        XCTAssertEqual(identity("meh - s"), identity("ctrl + shift + alt - s"))
        XCTAssertEqual(identity("meh + cmd - s"), identity("hyper - s"))
    }

    func testRepeatedModifiersDoNotCreateAnotherShortcut() {
        XCTAssertEqual(identity("ctrl + ctrl + alt - s"), identity("alt + ctrl - s"))
    }

    func testDistinctKeysAndFunctionModifiersRemainDistinct() {
        XCTAssertNotEqual(identity("hyper - s"), identity("hyper - d"))
        XCTAssertNotEqual(identity("alt - s"), identity("alt + fn - s"))
    }

    func testImplicitFunctionModifierDoesNotHideConflict() {
        for key in ["delete", "home", "end", "pageup", "pagedown", "insert", "left", "right", "up", "down"] + (1...20).map({ "f\($0)" }) {
            XCTAssertEqual(identity("alt - \(key)"), identity("alt + fn - \(key)"))
            XCTAssertEqual(identity(key), identity("fn - \(key)"))
        }
    }

    func testLeftAndRightModifiersRemainDistinct() {
        XCTAssertNotEqual(identity("lctrl + alt - s"), identity("rctrl + alt - s"))
        XCTAssertEqual(identity("alt + lctrl - s"), identity("lctrl + alt - s"))
    }

    func testModeScopeIsPreserved() {
        XCTAssertEqual(identity("resize < alt + shift - s"), identity("resize < shift + alt - s"))
        XCTAssertNotEqual(identity("resize < alt - s"), identity("alt - s"))
    }

    func testPlainKeysAndUnknownSyntaxKeepTheirIdentity() {
        XCTAssertEqual(identity(" S "), "s")
        XCTAssertEqual(identity("custom + alt - s"), "custom + alt - s")
        XCTAssertEqual(identity(""), "")
    }

    private func identity(_ combo: String) -> String {
        ShortcutComboIdentity.normalized(combo)
    }
}
#endif
