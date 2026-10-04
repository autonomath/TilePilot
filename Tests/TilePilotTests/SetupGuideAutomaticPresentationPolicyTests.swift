#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class SetupGuideAutomaticPresentationPolicyTests: XCTestCase {
    func testPresentsImmediatelyBeforeInitialSetupLandingHasBeenShown() {
        XCTAssertTrue(SetupGuideAutomaticPresentationPolicy.shouldPresentImmediatelyOnFirstLaunch(
            initialSetupLandingShown: false
        ))
    }

    func testDoesNotUseImmediatePresentationAfterInitialSetupLandingWasShown() {
        XCTAssertFalse(SetupGuideAutomaticPresentationPolicy.shouldPresentImmediatelyOnFirstLaunch(
            initialSetupLandingShown: true
        ))
    }

    func testDoesNotPresentDuringStartupGrace() {
        XCTAssertFalse(SetupGuideAutomaticPresentationPolicy.shouldPresent(
            startupGraceElapsed: false,
            hasBootstrapSnapshot: true,
            hasDoctorSnapshot: true,
            hasIncompleteEssentialSteps: true,
            dismissedThisSession: false
        ))
    }

    func testPresentsPersistentRequiredFailureAfterStartupGrace() {
        XCTAssertTrue(SetupGuideAutomaticPresentationPolicy.shouldPresent(
            startupGraceElapsed: true,
            hasBootstrapSnapshot: true,
            hasDoctorSnapshot: true,
            hasIncompleteEssentialSteps: true,
            dismissedThisSession: false
        ))
    }

    func testDoesNotPresentWhenSetupRecoveredDuringStartupGrace() {
        XCTAssertFalse(SetupGuideAutomaticPresentationPolicy.shouldPresent(
            startupGraceElapsed: true,
            hasBootstrapSnapshot: true,
            hasDoctorSnapshot: true,
            hasIncompleteEssentialSteps: false,
            dismissedThisSession: false
        ))
    }

    func testDoesNotPresentAgainAfterSessionDismissal() {
        XCTAssertFalse(SetupGuideAutomaticPresentationPolicy.shouldPresent(
            startupGraceElapsed: true,
            hasBootstrapSnapshot: true,
            hasDoctorSnapshot: true,
            hasIncompleteEssentialSteps: true,
            dismissedThisSession: true
        ))
    }
}
#endif
