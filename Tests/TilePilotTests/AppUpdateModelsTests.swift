#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class AppUpdateModelsTests: XCTestCase {
    func testAutomaticCheckRunsInitiallyAndAfterTwelveHours() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        XCTAssertTrue(AppUpdateCheckPolicy.shouldRun(
            enabled: true,
            isChecking: false,
            lastSuccessfulCheckAt: nil,
            now: now
        ))
        XCTAssertFalse(AppUpdateCheckPolicy.shouldRun(
            enabled: true,
            isChecking: false,
            lastSuccessfulCheckAt: now.addingTimeInterval(-(12 * 60 * 60) + 1),
            now: now
        ))
        XCTAssertTrue(AppUpdateCheckPolicy.shouldRun(
            enabled: true,
            isChecking: false,
            lastSuccessfulCheckAt: now.addingTimeInterval(-12 * 60 * 60),
            now: now
        ))
    }

    func testAutomaticCheckDoesNotRunWhenDisabledOrAlreadyChecking() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        XCTAssertFalse(AppUpdateCheckPolicy.shouldRun(
            enabled: false,
            isChecking: false,
            lastSuccessfulCheckAt: nil,
            now: now
        ))
        XCTAssertFalse(AppUpdateCheckPolicy.shouldRun(
            enabled: true,
            isChecking: true,
            lastSuccessfulCheckAt: nil,
            now: now
        ))
    }

    func testAutomaticCheckDelayUsesSuccessIntervalAndFailureRetry() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let sixHoursAgo = now.addingTimeInterval(-6 * 60 * 60)

        XCTAssertEqual(
            AppUpdateCheckPolicy.nextDelay(
                lastSuccessfulCheckAt: sixHoursAgo,
                latestAttemptResult: true,
                now: now
            ),
            6 * 60 * 60
        )
        XCTAssertEqual(
            AppUpdateCheckPolicy.nextDelay(
                lastSuccessfulCheckAt: sixHoursAgo,
                latestAttemptResult: false,
                now: now
            ),
            30 * 60
        )
        XCTAssertEqual(
            AppUpdateCheckPolicy.nextDelay(
                lastSuccessfulCheckAt: nil,
                latestAttemptResult: nil,
                now: now
            ),
            30 * 60
        )
    }

    func testNormalizedAppVersionStripsLeadingV() {
        XCTAssertEqual(normalizedAppVersionString(from: "v0.2.12"), "0.2.12")
    }

    func testVersionComparisonPadsMissingComponents() {
        XCTAssertEqual(AppVersion("0.2.12"), AppVersion("0.2.12.0"))
        XCTAssertTrue(AppVersion("0.2.13")! > AppVersion("0.2.12.9")!)
    }

    func testVersionComparisonIgnoresTrailingNonNumericSuffix() {
        XCTAssertEqual(normalizedAppVersionString(from: "v0.2.12-beta"), "0.2.12")
    }
}
#endif
