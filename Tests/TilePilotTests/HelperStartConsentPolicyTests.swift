#if canImport(XCTest)
import Foundation
import XCTest
@testable import TilePilot

final class HelperStartConsentPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "HelperStartConsentPolicyTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testFreshInstallForbidsAutomaticStart() {
        XCTAssertFalse(HelperStartConsentPolicy.allowsAutomaticStart(userDefaults: defaults))
    }

    func testStaleManagedHelperStateDoesNotImplyConsent() {
        defaults.set(true, forKey: "TilePilot.managedHelpersPreviouslyInstalled")
        XCTAssertFalse(HelperStartConsentPolicy.allowsAutomaticStart(userDefaults: defaults))
    }

    func testUserInitiatedStartEnablesAutomaticStart() {
        HelperStartConsentPolicy.recordUserInitiatedStart(userDefaults: defaults)
        XCTAssertTrue(HelperStartConsentPolicy.allowsAutomaticStart(userDefaults: defaults))
    }
}
#endif
