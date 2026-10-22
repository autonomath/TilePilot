import AppKit
import ApplicationServices

/// A temporary capture that runs ahead of skhd while the recording window is key.
@MainActor
final class ShortcutRecordingSession {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private weak var window: NSWindow?
    private var pendingKeyDown: NSEvent?
    private var onRecord: ((NSEvent) -> Void)?
    private var onCancel: (() -> Void)?

    /// Returns whether already-assigned global shortcuts can also be captured.
    func start(window: NSWindow?, onRecord: @escaping (NSEvent) -> Void, onCancel: @escaping () -> Void) -> Bool {
        stop()
        self.window = window
        self.onRecord = onRecord
        self.onCancel = onCancel

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.canCapture else { return event }
            self.handle(event)
            return nil
        }
        for (name, object) in [
            (NSApplication.didResignActiveNotification, nil as AnyObject?),
            (NSWindow.didResignKeyNotification, window),
            (NSWindow.willCloseNotification, window),
        ] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onCancel?() }
            })
        }

        // Never ask for permission from recording. Without existing trust the
        // local monitor still records shortcuts delivered to TilePilot.
        guard AXIsProcessTrusted() else { return false }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let session = Unmanaged<ShortcutRecordingSession>.fromOpaque(userInfo).takeUnretainedValue()
            let consumed = MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = session.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return false
                }
                guard session.canCapture, let keyEvent = NSEvent(cgEvent: event) else {
                    return false
                }
                session.handle(keyEvent)
                return true
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        pendingKeyDown = nil
        onRecord = nil
        onCancel = nil
        window = nil
    }

    private var canCapture: Bool {
        onRecord != nil && NSApp.isActive && window?.isKeyWindow == true
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if pendingKeyDown == nil && !event.isARepeat { pendingKeyDown = event }
        } else if event.type == .keyUp, let recorded = pendingKeyDown, recorded.keyCode == event.keyCode {
            // Wait for release so a held key cannot trigger its newly saved
            // shortcut (or its old skhd binding) through key-repeat.
            pendingKeyDown = nil
            onRecord?(recorded)
        }
    }
}
