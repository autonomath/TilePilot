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

    func testDiskImageAndTranslocatedCopiesAreTemporary() {
        XCTAssertTrue(TilePilotLaunchPolicy.isTemporaryAppLocation(
            bundlePath: "/Volumes/TilePilot/TilePilot.app",
            volumeIsReadOnly: true
        ))
        XCTAssertTrue(TilePilotLaunchPolicy.isTemporaryAppLocation(
            bundlePath: "/private/var/folders/ab/xyz/T/AppTranslocation/1234/d/TilePilot.app",
            volumeIsReadOnly: false
        ))
    }

    func testInstalledCopiesAreNotTemporary() {
        XCTAssertFalse(TilePilotLaunchPolicy.isTemporaryAppLocation(
            bundlePath: "/Applications/TilePilot.app",
            volumeIsReadOnly: false
        ))
        // Apps kept on a writable external drive are a real install location.
        XCTAssertFalse(TilePilotLaunchPolicy.isTemporaryAppLocation(
            bundlePath: "/Volumes/Data/Apps/TilePilot.app",
            volumeIsReadOnly: false
        ))
    }
}
#endif
