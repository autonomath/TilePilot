/// Keeps the scrub chord out of the front app without swallowing normal typing.
struct DesktopScrubKeyCapture {
    enum Decision: Equatable {
        case passThrough, consume, begin, commit, cancel

        var consumesEvent: Bool { self != .passThrough }
    }

    private var capturedKeyCodes: Set<Int64> = []
    private var triggerKeyCode: Int64?
    var isTriggerHeld: Bool { triggerKeyCode != nil }

    mutating func keyDown(
        _ keyCode: Int64,
        configuredTrigger: Int64?,
        modifiersMatch: Bool,
        isRepeat: Bool,
        isScrubbing: Bool
    ) -> Decision {
        // Keep consuming repeats even after modifiers are released or Escape
        // cancels the gesture. The matching key-up belongs to us too.
        if capturedKeyCodes.contains(keyCode) { return .consume }
        if keyCode == 53, isScrubbing {
            capturedKeyCodes.insert(keyCode)
            cancelTrigger()
            return .cancel
        }
        guard keyCode == configuredTrigger, modifiersMatch, !isRepeat else { return .passThrough }
        capturedKeyCodes.insert(keyCode)
        triggerKeyCode = keyCode
        return .begin
    }

    mutating func keyUp(_ keyCode: Int64) -> Decision {
        guard capturedKeyCodes.remove(keyCode) != nil else { return .passThrough }
        guard triggerKeyCode == keyCode else { return .consume }
        triggerKeyCode = nil
        return .commit
    }

    mutating func cancelTrigger() {
        triggerKeyCode = nil
    }

    mutating func reset() {
        capturedKeyCodes.removeAll()
        triggerKeyCode = nil
    }
}
