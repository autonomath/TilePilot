#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class PerformanceModelsTests: XCTestCase {
    func testPresetDefaultsMatchExpectedValues() {
        XCTAssertEqual(PerformanceSettings.balanced.foregroundPollingSeconds, 1.5)
        XCTAssertEqual(PerformanceSettings.balanced.keepOnTopEnforcementSeconds, 2.5)
        XCTAssertEqual(PerformanceSettings.responsive.backgroundPollingSeconds, 2.0)
        XCTAssertEqual(PerformanceSettings.passiveBaseline.backgroundPollingSeconds, 10.0)
        XCTAssertEqual(PerformanceSettings.lowCPU.keepOnTopEnforcementEnabled, false)
    }

    func testMatchesPresetDetectsBalancedAndCustom() {
        XCTAssertTrue(PerformanceSettings.balanced.matchesPreset(.balanced))
        XCTAssertEqual(PerformanceSettings.passiveBaseline.overlayRefreshPolicy, .reduced)

        var custom = PerformanceSettings.balanced
        custom.miniMapHoverTitlesEnabled = false

        XCTAssertFalse(custom.matchesPreset(.balanced))
    }

    func testBalancedDoesNotReportDefaultOverlayThrottlingAsDegraded() {
        let mode = PerformanceSettings.balanced.degradationMode(
            currentKeepOnTopEnforcementIntervalSeconds: 0,
            hasActiveOverlayTargets: true,
            hasVisibleWindowBadgePanels: true,
            hasActiveKeepOnTopWindows: false
        )

        XCTAssertEqual(mode, .full)
    }

    func testBalancedDoesNotReportDefaultIdlePollingAsDegraded() {
        let mode = PerformanceSettings.balanced.degradationMode(
            currentKeepOnTopEnforcementIntervalSeconds: 0,
            hasActiveOverlayTargets: false,
            hasVisibleWindowBadgePanels: false,
            hasActiveKeepOnTopWindows: false
        )

        XCTAssertEqual(mode, .full)
    }

    func testLowCPUPresetStillReportsExplicitSlowPolling() {
        let mode = PerformanceSettings.lowCPU.degradationMode(
            currentKeepOnTopEnforcementIntervalSeconds: 0,
            hasActiveOverlayTargets: false,
            hasVisibleWindowBadgePanels: false,
            hasActiveKeepOnTopWindows: false
        )

        XCTAssertEqual(mode, .degradedPolling)
    }

    func testLiveStateMismatchOnlyDegradesWhenYabaiReportsNoWindows() {
        XCTAssertTrue(LiveStateDegradationPolicy.isMaterialMismatch(yabaiWindowTotal: 0, fallbackWindowTotal: 3))
        XCTAssertFalse(LiveStateDegradationPolicy.isMaterialMismatch(yabaiWindowTotal: 4, fallbackWindowTotal: 8))
        XCTAssertFalse(LiveStateDegradationPolicy.isMaterialMismatch(yabaiWindowTotal: 0, fallbackWindowTotal: 2))
    }
}
#endif
