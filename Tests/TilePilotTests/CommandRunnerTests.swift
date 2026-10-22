#if canImport(XCTest)
import Foundation
import XCTest
@testable import TilePilot

final class CommandRunnerTests: XCTestCase {
    func testDrainsLargeStdoutAndStderrWhileChildRuns() async {
        let result = await CommandRunner().run(ShellCommand("/bin/sh", ["-c", """
            /usr/bin/head -c 1048576 /dev/zero &
            /usr/bin/head -c 1048576 /dev/zero >&2 &
            wait
            """], timeout: 3))

        XCTAssertTrue(result.isSuccess, "\(result.errorType), exit \(String(describing: result.exitStatus))")
        XCTAssertEqual(result.stdout.utf8.count, 1048576)
        XCTAssertEqual(result.stderr.utf8.count, 1048576)
    }

    func testPreservesUTF8AndOutputFromFastExit() async {
        let result = await CommandRunner().run(ShellCommand("/usr/bin/printf", ["windows 🪟 café\n"]))

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.stdout, "windows 🪟 café\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testPreservesNonzeroExitAndSeparateStreams() async {
        let result = await CommandRunner().run(ShellCommand("/bin/sh", ["-c",
            "printf payload; printf diagnostic >&2; exit 7",
        ]))

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.errorType, .nonZeroExit)
        XCTAssertEqual(result.exitStatus, 7)
        XCTAssertEqual(result.stdout, "payload")
        XCTAssertEqual(result.stderr, "diagnostic")
    }

    func testLaunchFailureReturnsWithoutWaitingForPipeEOF() async {
        let result = await CommandRunner().run(ShellCommand("/nonexistent/tilepilot-test-command"))

        XCTAssertEqual(result.errorType, .launchFailure)
        XCTAssertNil(result.exitStatus)
        XCTAssertFalse(result.stderr.isEmpty)
        XCTAssertLessThan(result.durationMs, 1000)
    }

    func testTimeoutKillsChildThatIgnoresTerminationAndKeepsPartialOutput() async {
        let result = await CommandRunner().run(ShellCommand("/bin/sh", ["-c",
            "trap '' TERM INT; printf partial; while :; do :; done",
        ], timeout: 0.2))

        XCTAssertEqual(result.errorType, .timeout)
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.stdout, "partial")
        XCTAssertLessThan(result.durationMs, 1500)
    }

    func testInheritedPipeDoesNotDelayCompletedCommand() async {
        let result = await CommandRunner().run(ShellCommand("/bin/sh", ["-c",
            "/bin/sleep 2 & printf finished",
        ], timeout: 0.5))

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.stdout, "finished")
        XCTAssertLessThan(result.durationMs, 1000)
    }
}
#endif
