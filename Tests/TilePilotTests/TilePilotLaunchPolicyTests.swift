#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class TilePilotLaunchPolicyTests: XCTestCase {
    func testRecognizesLoginLaunchArgument() {
        XCTAssertTrue(TilePilotLaunchPolicy.isLoginLaunch(arguments: [
            "/Applications/TilePilot.app/Contents/MacOS/TilePilot",
            TilePilotLaunchPolicy.loginLaunchArgument,
        ]))
    }

    func testManualLaunchDoesNotUseLoginLaunchMode() {
        XCTAssertFalse(TilePilotLaunchPolicy.isLoginLaunch(arguments: [
            "/Applications/TilePilot.app/Contents/MacOS/TilePilot",
        ]))
    }
}
#endif
