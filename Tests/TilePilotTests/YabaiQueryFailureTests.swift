#if canImport(XCTest)
import Foundation
import XCTest
@testable import TilePilot

final class YabaiQueryFailureTests: XCTestCase {
    private func result(
        _ error: CommandErrorType = .none,
        exit: Int32? = 0,
        stdout: String = "[{\"app\":\"PRIVATE WINDOW TITLE\"}]",
        stderr: String = ""
    ) -> CommandResult {
        CommandResult(command: "yabai", startedAt: Date(), endedAt: Date(),
                      exitStatus: exit, stdout: stdout, stderr: stderr, errorType: error)
    }

    private func summary(_ failure: CommandResult) -> String {
        YabaiQueryFailure.summary(windows: failure, spaces: result(), displays: result(), timeout: 1.5) ?? ""
    }

    func testSuccessfulQueriesHaveNoError() {
        XCTAssertNil(YabaiQueryFailure.summary(windows: result(), spaces: result(), displays: result(), timeout: 1.5))
    }

    func testNamesOnlyFailedQueryEvenWhenSuccessfulQueryHasOutput() {
        let message = YabaiQueryFailure.summary(
            windows: result(stderr: "irrelevant warning"),
            spaces: result(.timeout, exit: 15), displays: result(), timeout: 1.5
        ) ?? ""

        XCTAssertTrue(message.contains("--spaces query timed out after 1.5 seconds"))
        XCTAssertFalse(message.contains("--windows"))
        XCTAssertFalse(message.contains("PRIVATE WINDOW TITLE"))
        XCTAssertFalse(message.contains("irrelevant warning"))
        XCTAssertTrue(message.contains("retry automatically"))
    }

    func testReportsEachFailedQuery() {
        let message = YabaiQueryFailure.summary(
            windows: result(.timeout, exit: 15), spaces: result(.nonZeroExit, exit: 4),
            displays: result(.timeout, exit: 15), timeout: 1.5
        ) ?? ""

        XCTAssertTrue(message.contains("--windows query timed out"))
        XCTAssertTrue(message.contains("--spaces query failed (exit 4)"))
        XCTAssertTrue(message.contains("--displays query timed out"))
    }

    func testUnknownErrorNeverDisplaysPayload() {
        let message = summary(result(.nonZeroExit, exit: 2, stderr: "[{\"unknown\":\"PRIVATE DIAGNOSTIC\"}]"))

        XCTAssertTrue(message.contains("failed (exit 2)"))
        XCTAssertFalse(message.contains("PRIVATE"))
        XCTAssertFalse(message.contains("[{"))
    }

    func testLaunchFailureGivesInstallationGuidance() {
        let message = summary(result(.launchFailure, exit: nil))
        XCTAssertTrue(message.contains("could not start"))
        XCTAssertTrue(message.contains("helper installation"))
    }

    func testSocketFailureGivesStartGuidance() {
        let message = summary(result(.nonZeroExit, exit: 1, stderr: "yabai: could not connect to socket"))
        XCTAssertTrue(message.contains("socket unavailable"))
        XCTAssertTrue(message.contains("Start window control"))
    }

    func testPermissionFailureGivesAccessibilityGuidance() {
        let message = summary(result(.nonZeroExit, exit: 1, stderr: "Permission denied"))
        XCTAssertTrue(message.contains("permission denied"))
        XCTAssertTrue(message.contains("Accessibility"))
    }
}
#endif
