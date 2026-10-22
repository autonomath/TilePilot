#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class DesktopScrubKeyCaptureTests: XCTestCase {
    func testMatchingChordBeginsAndOwnsItsRelease() {
        var capture = DesktopScrubKeyCapture()

        let down = capture.keyDown(0, configuredTrigger: 0, modifiersMatch: true, isRepeat: false, isScrubbing: false)

        XCTAssertEqual(down, .begin)
        XCTAssertTrue(down.consumesEvent)
        XCTAssertTrue(capture.isTriggerHeld)
        let up = capture.keyUp(0)
        XCTAssertEqual(up, .commit)
        XCTAssertTrue(up.consumesEvent)
        XCTAssertFalse(capture.isTriggerHeld)
        XCTAssertEqual(capture.keyUp(0), .passThrough)
    }

    func testMatchingChordRepeatIsConsumedWithoutBeginningAgain() {
        var capture = DesktopScrubKeyCapture()
        _ = capture.keyDown(0, configuredTrigger: 0, modifiersMatch: true, isRepeat: false, isScrubbing: false)

        XCTAssertEqual(capture.keyDown(0, configuredTrigger: 0, modifiersMatch: true, isRepeat: true, isScrubbing: true), .consume)
        XCTAssertTrue(capture.isTriggerHeld)
        XCTAssertEqual(capture.keyUp(0), .commit)
    }

    func testModifierReleaseDoesNotLeakRemainingTriggerRepeatOrRelease() {
        var capture = DesktopScrubKeyCapture()
        _ = capture.keyDown(0, configuredTrigger: 0, modifiersMatch: true, isRepeat: false, isScrubbing: false)

        // The coordinator commits on modifier release before A is released.
        XCTAssertEqual(capture.keyDown(0, configuredTrigger: 0, modifiersMatch: false, isRepeat: true, isScrubbing: false), .consume)
        XCTAssertEqual(capture.keyUp(0), .commit)
        XCTAssertFalse(capture.isTriggerHeld)
    }

    func testWrongModifiersLeaveNormalTypingAndReleaseUntouched() {
        var capture = DesktopScrubKeyCapture()

        let down = capture.keyDown(0, configuredTrigger: 0, modifiersMatch: false, isRepeat: false, isScrubbing: false)

        XCTAssertEqual(down, .passThrough)
        XCTAssertFalse(down.consumesEvent)
        XCTAssertFalse(capture.isTriggerHeld)
        XCTAssertEqual(capture.keyUp(0), .passThrough)
    }

    func testUnrelatedKeyPassesWhileTriggerRemainsHeld() {
        var capture = DesktopScrubKeyCapture()
        _ = capture.keyDown(0, configuredTrigger: 0, modifiersMatch: true, isRepeat: false, isScrubbing: false)

        XCTAssertEqual(capture.keyDown(11, configuredTrigger: 0, modifiersMatch: true, isRepeat: false, isScrubbing: true), .passThrough)
        XCTAssertEqual(capture.keyUp(11), .passThrough)
        XCTAssertTrue(capture.isTriggerHeld)
        XCTAssertEqual(capture.keyUp(0), .commit)
    }

    func testAddingModifiersToPreviouslyPassedKeyDoesNotCaptureItsRepeatOrRelease() {
        var capture = DesktopScrubKeyCapture()
        XCTAssertEqual(capture.keyDown(0, configuredTrigger: 0, modifiersMatch: false, isRepeat: false, isScrubbing: false), .passThrough)

        XCTAssertEqual(capture.keyDown(0, configuredTrigger: 0, modifiersMatch: true, isRepeat: true, isScrubbing: false), .passThrough)
        XCTAssertFalse(capture.isTriggerHeld)
        XCTAssertEqual(capture.keyUp(0), .passThrough)
    }

    func testEscapeCancelsAndKeepsBothKeysOwnedUntilReleased() {
        var capture = DesktopScrubKeyCapture()
        _ = capture.keyDown(0, configuredTrigger: 0, modifiersMatch: true, isRepeat: false, isScrubbing: false)

        XCTAssertEqual(capture.keyDown(53, configuredTrigger: 0, modifiersMatch: true, isRepeat: false, isScrubbing: true), .cancel)
        XCTAssertFalse(capture.isTriggerHeld)
        XCTAssertEqual(capture.keyDown(53, configuredTrigger: 0, modifiersMatch: true, isRepeat: true, isScrubbing: false), .consume)
        XCTAssertEqual(capture.keyDown(0, configuredTrigger: 0, modifiersMatch: true, isRepeat: true, isScrubbing: false), .consume)
        XCTAssertFalse(capture.isTriggerHeld)
        XCTAssertEqual(capture.keyUp(53), .consume)
        XCTAssertEqual(capture.keyUp(0), .consume)
        XCTAssertEqual(capture.keyDown(0, configuredTrigger: 0, modifiersMatch: true, isRepeat: false, isScrubbing: false), .begin)
    }

    func testEscapeWithoutActiveScrubPassesNormally() {
        var capture = DesktopScrubKeyCapture()

        XCTAssertEqual(capture.keyDown(53, configuredTrigger: 0, modifiersMatch: true, isRepeat: false, isScrubbing: false), .passThrough)
        XCTAssertEqual(capture.keyUp(53), .passThrough)
    }

    func testCancellationStopsHeldTriggerButKeepsItsRemainingEventsConsumed() {
        var capture = DesktopScrubKeyCapture()
        _ = capture.keyDown(0, configuredTrigger: 0, modifiersMatch: true, isRepeat: false, isScrubbing: false)

        capture.cancelTrigger()

        XCTAssertFalse(capture.isTriggerHeld)
        XCTAssertEqual(capture.keyDown(0, configuredTrigger: 0, modifiersMatch: true, isRepeat: true, isScrubbing: false), .consume)
        XCTAssertFalse(capture.isTriggerHeld)
        XCTAssertEqual(capture.keyUp(0), .consume)
    }

    func testReconfigurationRetainsOldKeyOwnershipWithoutCommittingNewTrigger() {
        var capture = DesktopScrubKeyCapture()
        _ = capture.keyDown(0, configuredTrigger: 0, modifiersMatch: true, isRepeat: false, isScrubbing: false)
        capture.cancelTrigger()

        XCTAssertEqual(capture.keyDown(11, configuredTrigger: 11, modifiersMatch: true, isRepeat: false, isScrubbing: false), .begin)
        XCTAssertEqual(capture.keyDown(0, configuredTrigger: 11, modifiersMatch: false, isRepeat: true, isScrubbing: true), .consume)
        XCTAssertEqual(capture.keyUp(0), .consume)
        XCTAssertTrue(capture.isTriggerHeld)
        XCTAssertEqual(capture.keyUp(11), .commit)
        XCTAssertFalse(capture.isTriggerHeld)
    }

    func testResetClearsStaleTriggerAndEscapeOwnership() {
        var capture = DesktopScrubKeyCapture()
        _ = capture.keyDown(0, configuredTrigger: 0, modifiersMatch: true, isRepeat: false, isScrubbing: false)
        _ = capture.keyDown(53, configuredTrigger: 0, modifiersMatch: true, isRepeat: false, isScrubbing: true)

        capture.reset()

        XCTAssertFalse(capture.isTriggerHeld)
        XCTAssertEqual(capture.keyUp(0), .passThrough)
        XCTAssertEqual(capture.keyUp(53), .passThrough)
        XCTAssertEqual(capture.keyDown(0, configuredTrigger: 0, modifiersMatch: true, isRepeat: true, isScrubbing: false), .passThrough)
        XCTAssertEqual(capture.keyDown(0, configuredTrigger: 0, modifiersMatch: true, isRepeat: false, isScrubbing: false), .begin)
    }

    func testModifierOnlyConfigurationDoesNotCaptureCharactersAndCanCancelWithEscape() {
        var capture = DesktopScrubKeyCapture()

        XCTAssertEqual(capture.keyDown(0, configuredTrigger: nil, modifiersMatch: true, isRepeat: false, isScrubbing: true), .passThrough)
        XCTAssertEqual(capture.keyUp(0), .passThrough)
        XCTAssertFalse(capture.isTriggerHeld)
        XCTAssertEqual(capture.keyDown(53, configuredTrigger: nil, modifiersMatch: true, isRepeat: false, isScrubbing: true), .cancel)
        XCTAssertEqual(capture.keyUp(53), .consume)
    }
}
#endif
