#if canImport(XCTest)
import XCTest
@testable import TilePilot

/// Abort lines below are copied from the bundled yabai 7.1.25 binary and skhd 0.3.9 source.
final class HelperStartFailureDiagnosisTests: XCTestCase {
    func testRecognizesYabaiAccessibilityAbort() {
        let failure = HelperStartFailureDiagnosis.failure(
            for: .yabai,
            errorLog: "yabai: could not access accessibility features! abort..\n"
        )
        XCTAssertEqual(failure, HelperStartFailure(helper: .yabai, reason: .accessibilityNotAllowed))
    }

    func testRecognizesYabaiSeparateSpacesAbort() {
        let failure = HelperStartFailureDiagnosis.failure(
            for: .yabai,
            errorLog: "yabai: 'display has separate spaces' is disabled! abort..\n"
        )
        XCTAssertEqual(failure?.reason, .separateSpacesOff)
    }

    func testRecognizesSkhdAccessibilityAbort() {
        let failure = HelperStartFailureDiagnosis.failure(
            for: .skhd,
            errorLog: "skhd: must be run with accessibility access! abort..\n"
        )
        XCTAssertEqual(failure?.reason, .accessibilityNotAllowed)
    }

    func testNamesTheAppHoldingSecureKeyboardEntry() {
        let failure = HelperStartFailureDiagnosis.failure(
            for: .skhd,
            errorLog: "skhd: secure keyboard entry is enabled by (812) 'Terminal'! abort..\n"
        )
        XCTAssertEqual(failure?.reason, .secureKeyboardEntry(appName: "Terminal"))
    }

    func testSecureKeyboardEntryWithoutKnownApp() {
        let failure = HelperStartFailureDiagnosis.failure(
            for: .skhd,
            errorLog: "skhd: secure keyboard entry is enabled! abort..\n"
        )
        XCTAssertEqual(failure?.reason, .secureKeyboardEntry(appName: nil))
    }

    func testNewestAbortLineWins() {
        let log = """
        yabai: could not access accessibility features! abort..
        yabai: 'display has separate spaces' is disabled! abort..
        """
        XCTAssertEqual(HelperStartFailureDiagnosis.failure(for: .yabai, errorLog: log)?.reason, .separateSpacesOff)
    }

    func testIgnoresUnrelatedOutputAndOtherHelpersLines() {
        XCTAssertNil(HelperStartFailureDiagnosis.failure(for: .yabai, errorLog: "yabai: config file not found\n"))
        XCTAssertNil(HelperStartFailureDiagnosis.failure(
            for: .yabai,
            errorLog: "skhd: must be run with accessibility access! abort..\n"
        ))
        XCTAssertNil(HelperStartFailureDiagnosis.failure(for: .skhd, errorLog: ""))
    }

    func testAdviceNamesBothHelpersAndAsksForASecondStart() {
        let advice = HelperStartFailureDiagnosis.advice(for: [
            HelperStartFailure(helper: .yabai, reason: .accessibilityNotAllowed),
            HelperStartFailure(helper: .skhd, reason: .accessibilityNotAllowed),
        ])
        XCTAssertEqual(advice?.problem, "macOS has not allowed yabai and skhd in Accessibility yet.")
        XCTAssertTrue(advice?.fix.hasSuffix("Then click Start Window Control again.") == true)
    }

    func testNoAdviceWithoutFailures() {
        XCTAssertNil(HelperStartFailureDiagnosis.advice(for: []))
    }
}
#endif
