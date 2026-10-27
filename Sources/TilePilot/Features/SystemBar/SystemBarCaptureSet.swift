import AppKit
import CoreGraphics
import Foundation

/// The ScreenCaptureKit streams the mirror copies icon pixels from: one per display whose real
/// menu bar draws shown icons. A stream that fails to start, or stops on its own (display
/// reconnect, lock screen), is dropped so its last pixels are never shown as live, and retried
/// after a growing delay (see SystemBarCapturePolicy).
@MainActor
final class SystemBarCaptureSet {
    struct Failure {
        let at: Date
        let reason: String
        /// Failures in a row; a successful start clears the record.
        let attempts: Int
    }

    private(set) var captures: [CGDirectDisplayID: MenuBarStripCapture] = [:]
    private(set) var failures: [CGDirectDisplayID: Failure] = [:]
    /// A capture delivered changed regions.
    var onFrame: () -> Void = {}
    /// A capture failed to start; `attempts` counts the failures in a row for that display.
    var onStartFailure: (_ error: Error, _ attempts: Int) -> Void = { _, _ in }

    var isEmpty: Bool { captures.isEmpty }
    var isAnyRunning: Bool { captures.values.contains { $0.isRunning } }

    func capture(for displayID: CGDirectDisplayID) -> MenuBarStripCapture? {
        captures[displayID]
    }

    /// Runs exactly the wanted streams: `strip` is the real bar in points relative to its
    /// display, `scale` the display's backing scale.
    func update(wanted: [CGDirectDisplayID: (strip: CGRect, scale: CGFloat)], colorSpace: CGColorSpace?) {
        for (displayID, capture) in captures where wanted[displayID] == nil || wanted[displayID]?.strip != capture.stripRect {
            captures.removeValue(forKey: displayID)
            Task { await capture.stop() }
        }
        for (displayID, spec) in wanted where captures[displayID] == nil {
            if let failure = failures[displayID],
               Date().timeIntervalSince(failure.at) < SystemBarCapturePolicy.retryDelay(afterFailures: failure.attempts) {
                continue
            }
            start(displayID: displayID, strip: spec.strip, scale: spec.scale, colorSpace: colorSpace)
        }
        for (displayID, capture) in captures where !capture.isStartingOrRunning {
            let reason: String
            if case let .stopped(why) = capture.state { reason = why } else { reason = "not running" }
            captures.removeValue(forKey: displayID)
            recordFailure(displayID, reason: reason)
            Task { await capture.stop() }
        }
    }

    private func start(displayID: CGDirectDisplayID, strip: CGRect, scale: CGFloat, colorSpace: CGColorSpace?) {
        let capture = MenuBarStripCapture(displayID: displayID, stripRect: strip, scale: scale, targetColorSpace: colorSpace) { [weak self] in
            Task { @MainActor in
                self?.onFrame()
            }
        }
        capture.markStarting()
        captures[displayID] = capture
        Task { [weak self] in
            do {
                try await capture.start()
                guard let self, self.captures[displayID] === capture else { return }
                self.failures[displayID] = nil
            } catch {
                guard let self else { return }
                if self.captures[displayID] === capture {
                    self.captures.removeValue(forKey: displayID)
                }
                let attempts = self.recordFailure(displayID, reason: error.localizedDescription)
                self.onStartFailure(error, attempts)
            }
        }
    }

    @discardableResult
    private func recordFailure(_ displayID: CGDirectDisplayID, reason: String) -> Int {
        let attempts = (failures[displayID]?.attempts ?? 0) + 1
        failures[displayID] = Failure(at: Date(), reason: reason, attempts: attempts)
        return attempts
    }

    func stopAll() {
        let running = captures.values
        captures.removeAll()
        for capture in running {
            Task { await capture.stop() }
        }
    }

    /// Lets the next update retry every display right away.
    func clearFailures() {
        failures.removeAll()
    }

    /// Rectangles (points relative to each strip) to copy from each display's capture.
    func setRegions(_ regionsByDisplay: [CGDirectDisplayID: [String: CGRect]]) {
        for (displayID, capture) in captures {
            capture.setRegions(regionsByDisplay[displayID] ?? [:])
        }
    }

    /// The stretch of each display's bar to watch for icons moving (see MenuBarStripCapture).
    func setLayoutRegions(_ regionsByDisplay: [CGDirectDisplayID: CGRect]) {
        for (displayID, capture) in captures {
            capture.setLayoutRegion(regionsByDisplay[displayID])
        }
    }

    /// Development route: stops every running stream as a display change would.
    func simulateUnexpectedStop() -> Int {
        let running = captures.values.filter(\.isRunning)
        for capture in running {
            Task { await capture.simulateUnexpectedStop() }
        }
        return running.count
    }

    var summary: String {
        let failed = failures.map { "\($0.key): \($0.value.reason)" }.sorted()
        return "captures \(captures.keys.sorted()) running \(captures.values.filter(\.isRunning).count) failed \(failed)"
    }
}
