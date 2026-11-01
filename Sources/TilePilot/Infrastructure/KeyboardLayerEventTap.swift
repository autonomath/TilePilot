import AppKit
import ApplicationServices
import IOKit
import IOKit.hidsystem
import os

/// Runs the keyboard-layer event tap on its own thread, so typing never waits on TilePilot's
/// main thread. KeyboardLayerEngine decides what each key means; this class feeds it key
/// events and carries out the effects.
final class KeyboardLayerEventTap: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case off
        case running
        case needsAccessibility
        case failed
    }

    /// Marks events TilePilot posts, so the tap lets its own output through.
    static let syntheticEventMarker: Int64 = 0x5450_4C41_5945_5253
    /// After this long without a key event, held keys are checked against the keyboard before
    /// the next key, in case Secure Input, sleep, or a paused tap hid their release.
    static let staleKeyCheckDelay: TimeInterval = 0.5
    /// F18, F19, and F20: the keys Hyper Key tools remap Caps Lock to. Raycast uses F20.
    static let hyperKeyStandIns: [UInt16] = [79, 80, 90]
    private static let logger = Logger(subsystem: "com.klode.tilepilot", category: "KeyboardLayers")

    private let lock = NSLock()
    // Guarded by lock: shared by the main thread and the tap thread.
    private var engine = KeyboardLayerEngine()
    private var suspended = false
    private var lastKeyEventTime: TimeInterval = 0
    private var originalKeyDowns: [UInt16: CGEvent] = [:]
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var actionHandler: (@Sendable (KeyboardLayerAction) -> Void)?
    // Used only on the tap thread.
    private let eventSource: CGEventSource?
    private let capsLockState = CapsLockLockState()
    // Main thread only.
    private(set) var state: State = .off

    init() {
        eventSource = CGEventSource(stateID: .privateState)
        eventSource?.localEventsSuppressionInterval = 0
    }

    /// Called on the main thread for each TilePilot feature or app a layer key runs.
    func setActionHandler(_ handler: @escaping @Sendable (KeyboardLayerAction) -> Void) {
        lock.withLock { actionHandler = handler }
    }

    /// Starts, updates, or stops the tap. With no layers it stops completely.
    @discardableResult
    func apply(_ layers: [KeyboardLayerEngine.Layer]) -> State {
        guard !layers.isEmpty else {
            stop()
            return state
        }
        lock.withLock {
            guard engine.layers != layers else { return }
            engine.configure(layers)
            originalKeyDowns.removeAll()
        }
        if hasTap { return ensureRunning() }
        state = start()
        return state
    }

    /// Turns a tap that macOS disabled back on, and stops it if Accessibility was removed.
    @discardableResult
    func ensureRunning() -> State {
        guard hasTap else { return state }
        guard AXIsProcessTrusted() else {
            stop()
            state = .needsAccessibility
            return state
        }
        let tap = lock.withLock { self.tap }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            reset()
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        state = tap.map { CGEvent.tapIsEnabled(tap: $0) } == true ? .running : .failed
        return state
    }

    /// Forgets held keys, for sleep, lock, user switching, and configuration changes.
    func reset() {
        lock.withLock {
            engine.reset()
            originalKeyDowns.removeAll()
        }
    }

    /// While TilePilot records a shortcut, every key goes through untouched.
    func setSuspended(_ value: Bool) {
        lock.withLock {
            guard suspended != value else { return }
            suspended = value
            engine.reset()
            originalKeyDowns.removeAll()
        }
    }

    func stop() {
        let (tap, source, runLoop) = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?, CFRunLoop?) in
            let parts = (self.tap, runLoopSource, tapRunLoop)
            self.tap = nil
            runLoopSource = nil
            tapRunLoop = nil
            engine.configure([])
            originalKeyDowns.removeAll()
            return parts
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop {
            if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFRunLoopStop(runLoop)
        }
        state = .off
    }

    private var hasTap: Bool {
        lock.withLock { tap != nil }
    }

    private func start() -> State {
        // Never prompt here: an active keyboard tap needs Accessibility the user already granted.
        guard AXIsProcessTrusted() else { return .needsAccessibility }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<KeyboardLayerEventTap>.fromOpaque(userInfo).takeUnretainedValue()
            return owner.handle(proxy: proxy, type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Self.logger.error("Keyboard tap refused: accessibility=\(AXIsProcessTrusted()) postEvents=\(CGPreflightPostEventAccess()) listenEvents=\(CGPreflightListenEventAccess())")
            return .failed
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return .failed
        }
        lock.withLock {
            self.tap = tap
            runLoopSource = source
        }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let runLoop = CFRunLoopGetCurrent()
            lock.withLock {
                tapRunLoop = runLoop
                if let runLoopSource { CFRunLoopAddSource(runLoop, runLoopSource, .commonModes) }
            }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "TilePilot Keyboard Layers"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            Self.logger.error("Keyboard tap created but stayed disabled")
            return .failed
        }
        return .running
    }

    /// Runs on the tap thread.
    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS paused the tap. Forget held keys so nothing stays stuck, then resume.
            lock.withLock {
                engine.reset()
                originalKeyDowns.removeAll()
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return passThrough
        }
        guard type == .keyDown || type == .keyUp,
              event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker else {
            return passThrough
        }
        let rawKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard rawKeyCode >= 0, rawKeyCode <= Int64(UInt16.max) else { return passThrough }
        let keyCode = UInt16(rawKeyCode)
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        defer { lock.unlock() }
        guard !suspended, !engine.layers.isEmpty else { return passThrough }

        let output: KeyboardLayerEngine.Output
        if type == .keyDown {
            if engine.isTrackingKeys, now - lastKeyEventTime >= Self.staleKeyCheckDelay {
                engine.forgetReleasedKeys(isDown: Self.isKeyDown)
            }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            var modifiers = KeyboardLayerModifiers(event.flags)
            if !isRepeat, modifiers.isEmpty, engine.startsLayer(keyCode), otherHyperKeyIsHeld() {
                // Another tool's Hyper Key is down and adds ⌃⌥⇧⌘ after this tap, so the trigger
                // is part of a Hyper shortcut, like Shift+Tab is a Shift shortcut.
                modifiers = .hyper
            }
            output = engine.keyDown(keyCode, modifiers: modifiers, isRepeat: isRepeat, at: now)
            if output.consumesEvent, !isRepeat, let copy = event.copy() {
                // Kept so a key that turns out to be typing is replayed exactly as pressed.
                originalKeyDowns[keyCode] = copy
            }
        } else {
            output = engine.keyUp(keyCode, at: now)
        }
        lastKeyEventTime = now
        perform(output.effects, proxy: proxy)
        if !engine.isTrackingKeys {
            originalKeyDowns.removeAll()
        } else if type == .keyUp {
            originalKeyDowns[keyCode] = nil
        }
        return output.consumesEvent ? nil : passThrough
    }

    /// Runs on the tap thread with the lock held.
    private func perform(_ effects: [KeyboardLayerEngine.Effect], proxy: CGEventTapProxy) {
        for effect in effects {
            switch effect {
            case .replay(let chord):
                // Posted from the tap, typed keys land in order, ahead of the current event.
                for event in replayEvents(for: chord) { event.tapPostEvent(proxy) }
            case .toggleCapsLock:
                capsLockState.toggle()
            case .send(let chord):
                // Posted at the HID level, shortcuts reach skhd, Raycast, and every other tap.
                for event in shortcutEvents(for: chord) { event.post(tap: .cghidEventTap) }
            case .run(let action):
                guard let handler = actionHandler else { continue }
                DispatchQueue.main.async { handler(action) }
            }
        }
    }

    private func replayEvents(for chord: KeyboardLayerChord) -> [CGEvent] {
        let original = originalKeyDowns[chord.keyCode]?.copy()
        guard let down = original
            ?? CGEvent(keyboardEventSource: eventSource, virtualKey: chord.keyCode, keyDown: true) else {
            return []
        }
        if original == nil { down.flags = chord.modifiers.cgEventFlags }
        down.type = .keyDown
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        guard let up = down.copy() else { return [down] }
        up.type = .keyUp
        return [down, up]
    }

    /// A press and release that carry their own modifiers. TilePilot never posts a modifier
    /// key-down, so no modifier can stay stuck.
    private func shortcutEvents(for chord: KeyboardLayerChord) -> [CGEvent] {
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: chord.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: chord.keyCode, keyDown: false) else {
            return []
        }
        let flags = chord.modifiers.cgEventFlags.union(Self.implicitFlags(for: chord.keyCode))
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        }
        return [down, up]
    }

    /// Real arrow, navigation, and function key presses carry these flags, and some apps check them.
    private static func implicitFlags(for keyCode: UInt16) -> CGEventFlags {
        if (123...126).contains(keyCode) { return [.maskSecondaryFn, .maskNumericPad] }
        if functionAndNavigationKeyCodes.contains(keyCode) { return .maskSecondaryFn }
        return []
    }

    private static let functionAndNavigationKeyCodes: Set<UInt16> = [
        64, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113,
        114, 115, 116, 117, 118, 119, 120, 121, 122,
    ]

    private static func isKeyDown(_ keyCode: UInt16) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: keyCode)
            || CGEventSource.keyState(.combinedSessionState, key: keyCode)
    }

    /// Runs with the lock held. A layer's own trigger (F18 for Caps Lock) doesn't count.
    private func otherHyperKeyIsHeld() -> Bool {
        Self.hyperKeyStandIns.contains { keyCode in
            !engine.layers.contains { $0.triggerKeyCode == keyCode } && Self.isKeyDown(keyCode)
        }
    }
}

/// Toggles Caps Lock the way the key itself does, including its light.
final class CapsLockLockState: @unchecked Sendable {
    private var connection: io_connect_t = 0

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func toggle() {
        guard let connection = openConnection() else { return }
        var isOn = false
        guard IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &isOn) == KERN_SUCCESS else { return }
        _ = IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), !isOn)
    }

    private func openConnection() -> io_connect_t? {
        if connection != 0 { return connection }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var opened: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &opened) == KERN_SUCCESS else {
            return nil
        }
        connection = opened
        return opened
    }
}
