#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class SystemModelsTests: XCTestCase {
    func testMissionControlChecklistItemsProvideDefaultsWhenChecksMissing() {
        let items = buildMissionControlChecklistItems(from: [])

        XCTAssertEqual(items.map(\.id), ["mru-spaces", "spans-displays"])
        XCTAssertEqual(items.map(\.expectedValue), ["Off", "On"])
        XCTAssertEqual(items.map(\.status), [.unknown, .unknown])
        XCTAssertNil(items[0].actualValue)
        XCTAssertNil(items[1].actualValue)
    }

    func testMissionControlChecklistItemsTranslateRawValuesToUIValues() {
        let items = buildMissionControlChecklistItems(from: [
            MissionControlCheck(
                key: "mru-spaces",
                expected: "0",
                actual: "1",
                status: .warning,
                message: "MRU spaces enabled"
            ),
            MissionControlCheck(
                key: "spans-displays",
                expected: "0",
                actual: "0",
                status: .pass,
                message: "Separate spaces enabled"
            ),
        ])

        XCTAssertEqual(items[0].title, "Automatically rearrange Spaces based on most recent use")
        XCTAssertEqual(items[0].expectedValue, "Off")
        XCTAssertEqual(items[0].actualValue, "On")
        XCTAssertEqual(items[1].title, "Displays have separate Spaces")
        XCTAssertEqual(items[1].expectedValue, "On")
        XCTAssertEqual(items[1].actualValue, "On")
    }

    func testSetupGuideStepDoesNotRepeatPrimaryActionAsSecondary() {
        let step = SetupGuideStep(
            kind: .startHelperServices,
            category: .essential,
            title: "Confirm Window Control",
            summary: "Waiting for yabai.",
            whyItMatters: "Window control depends on yabai.",
            whatToDo: "Use Recheck after approving permissions.",
            detail: nil,
            verificationText: nil,
            status: .notice,
            isBlocking: true,
            isSkippable: true,
            primaryAction: .recheck,
            secondaryActions: [.openAccessibilitySettings, .recheck]
        )

        XCTAssertEqual(step.displayedSecondaryActions, [.openAccessibilitySettings])
    }

    func testSetupGuideStepHidesSatisfiedRecheckSecondaryAction() {
        let step = SetupGuideStep(
            kind: .installHelpers,
            category: .essential,
            title: "Prepare Window Control",
            summary: "Components are installed.",
            whyItMatters: "Window control depends on local helpers.",
            whatToDo: "Nothing else is required.",
            detail: nil,
            verificationText: nil,
            status: .good,
            isBlocking: true,
            isSkippable: true,
            primaryAction: nil,
            secondaryActions: [.recheck]
        )

        XCTAssertEqual(step.displayedSecondaryActions, [])
    }
}
#endif
