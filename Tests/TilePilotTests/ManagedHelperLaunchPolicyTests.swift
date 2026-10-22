#if canImport(XCTest)
import Foundation
import XCTest
@testable import TilePilot

final class ManagedHelperLaunchPolicyTests: XCTestCase {
    func testActivationStartsEachAgentOnlyOnce() {
        let arguments = ManagedHelperLaunchPolicy.activationArguments(
            domain: "gui/501",
            label: "com.klode.tilepilot.yabai",
            plistPath: "/tmp/helper.plist"
        )

        XCTAssertEqual(arguments, [
            ["bootout", "gui/501/com.klode.tilepilot.yabai"],
            ["bootstrap", "gui/501", "/tmp/helper.plist"],
        ])
        XCTAssertFalse(arguments.joined().contains("kickstart"))
    }

    func testGeneratedLaunchAgentDoesNotKeepPermissionBlockedHelperAlive() throws {
        let plist = ManagedHelperService.shared.launchAgentPlist(for: .yabai)
        let data = try XCTUnwrap(plist.data(using: .utf8))

        XCTAssertTrue(plist.contains("<key>RunAtLoad</key>"))
        XCTAssertFalse(plist.contains("<key>KeepAlive</key>"))
        XCTAssertFalse(ManagedHelperLaunchPolicy.requiresPromptLoopRepair(plistData: data))
    }

    func testLegacyUnconditionalKeepAliveRequiresRepair() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "test", "KeepAlive": true],
            format: .xml,
            options: 0
        )

        XCTAssertTrue(ManagedHelperLaunchPolicy.requiresPromptLoopRepair(plistData: data))
    }

    func testOneShotLaunchAgentDoesNotRequireRepair() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "test", "RunAtLoad": true],
            format: .xml,
            options: 0
        )

        XCTAssertFalse(ManagedHelperLaunchPolicy.requiresPromptLoopRepair(plistData: data))
    }
}
#endif
