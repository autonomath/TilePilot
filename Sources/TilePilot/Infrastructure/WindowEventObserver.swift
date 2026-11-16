import AppKit
import ApplicationServices

/// Accessibility notifications from other apps' windows, so overlays react as windows change
/// instead of waiting for the next poll. yabai listens to the same notifications.
@MainActor
final class WindowEventObserver {
    /// A window moved or resized: its window ID and new top-origin frame.
    var onFrameChange: ((Int, CGRect) -> Void)?
    /// Focus, stacking, or the set of windows changed.
    var onWindowsChange: (() -> Void)?

    private var observers: [pid_t: AXObserver] = [:]
    private var retryAfter: [pid_t: Date] = [:]

    private static let appNotifications = [
        kAXWindowResizedNotification, kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]

    /// Observes exactly these apps. Call again as apps come and go.
    func observe(pids: Set<pid_t>) {
        for (pid, observer) in observers where !pids.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers[pid] = nil
        }
        retryAfter = retryAfter.filter { pids.contains($0.key) }
        guard AXIsProcessTrusted() else { return }
        let now = Date()
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for pid in pids where observers[pid] == nil && (retryAfter[pid] ?? .distantPast) < now {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            var created: AXObserver?
            guard AXObserverCreate(pid, windowEventCallback, &created) == .success, let observer = created,
                  AXObserverAddNotification(observer, app, kAXWindowMovedNotification as CFString, refcon) == .success else {
                // A just-launched or hung app refuses; asking again on every pass would stall the main thread.
                retryAfter[pid] = now.addingTimeInterval(3)
                continue
            }
            for name in Self.appNotifications {
                AXObserverAddNotification(observer, app, name as CFString, refcon)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers[pid] = observer
        }
    }

    fileprivate func handle(_ element: AXUIElement, _ notification: String) {
        guard notification == kAXWindowMovedNotification || notification == kAXWindowResizedNotification else {
            onWindowsChange?()
            return
        }
        AXUIElementSetMessagingTimeout(element, 0.2)
        if let windowID = AccessibilityWindowFrames.windowID(of: element),
           let frame = AccessibilityWindowFrames.frame(of: element) {
            onFrameChange?(windowID, frame)
        } else {
            onWindowsChange?()
        }
    }
}

private let windowEventCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let receiver = Unmanaged<WindowEventObserver>.fromOpaque(refcon).takeUnretainedValue()
    // The observer's source is on the main run loop, so this already runs on the main thread.
    nonisolated(unsafe) let element = element
    let name = notification as String
    MainActor.assumeIsolated {
        receiver.handle(element, name)
    }
}

