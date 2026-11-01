import Foundation

/// Decides, key by key, whether a held trigger turns the next keys into layer actions or lets
/// them type. It never touches events itself: the event tap feeds it key presses and carries
/// out the effects it returns, so every transition can be tested without a keyboard.
struct KeyboardLayerEngine: Sendable {
    struct Layer: Equatable, Sendable {
        let id: UUID
        let triggerKeyCode: UInt16
        let tapsCapsLock: Bool
        let sendsHyperForUnboundKeys: Bool
        let bindings: [KeyboardLayerChord: KeyboardLayerAction]
    }

    enum Effect: Equatable, Sendable {
        /// Type a key the user pressed: a press and release placed ahead of the current event.
        case replay(KeyboardLayerChord)
        /// Toggle Caps Lock, the Caps Lock trigger's own job when tapped.
        case toggleCapsLock
        /// Press and release a shortcut: a Send Shortcut binding or ⌃⌥⇧⌘ + key.
        case send(KeyboardLayerChord)
        /// Run a TilePilot feature or open an app.
        case run(KeyboardLayerAction)
    }

    struct Output: Equatable, Sendable {
        var consumesEvent: Bool
        var effects: [Effect] = []

        static let pass = Output(consumesEvent: false)
        static let consume = Output(consumesEvent: true)
    }

    /// Keys pressed sooner than this after the trigger may be fast typing.
    static let holdThreshold: TimeInterval = 0.2
    /// A trigger held at least this long and released alone types nothing.
    static let tapLimit: TimeInterval = 1.0

    private enum KeyRole: Equatable, Sendable {
        case swallow
        case resend(KeyboardLayerChord)
    }

    private struct BufferedKey: Equatable, Sendable {
        let chord: KeyboardLayerChord
        let action: KeyboardLayerAction
    }

    private struct Hold: Sendable {
        let layer: Layer
        let downAt: TimeInterval
        var used = false
        var buffered: [BufferedKey] = []
    }

    private(set) var layers: [Layer] = []
    private var hold: Hold?
    /// Keys whose press TilePilot consumed. Their repeats and release are consumed too, even
    /// after the layer ends, so the front app never sees half of a key press.
    private var ownedKeys: [UInt16: KeyRole] = [:]

    var heldTriggerKeyCode: UInt16? { hold?.layer.triggerKeyCode }
    var isTrackingKeys: Bool { hold != nil || !ownedKeys.isEmpty }

    /// Whether this key would start a layer if pressed now.
    func startsLayer(_ keyCode: UInt16) -> Bool {
        hold == nil && layers.contains { $0.triggerKeyCode == keyCode }
    }

    mutating func configure(_ layers: [Layer]) {
        self.layers = layers
        reset()
    }

    mutating func reset() {
        hold = nil
        ownedKeys.removeAll()
    }

    /// Forgets keys that are no longer down, for example when Secure Input or sleep hid their
    /// release. A forgotten trigger ends its layer without typing anything.
    mutating func forgetReleasedKeys(isDown: (UInt16) -> Bool) {
        if let current = hold, !isDown(current.layer.triggerKeyCode) {
            for key in current.buffered { ownedKeys[key.chord.keyCode] = .swallow }
            endHold()
        }
        ownedKeys = ownedKeys.filter { isDown($0.key) }
    }

    mutating func keyDown(
        _ keyCode: UInt16,
        modifiers: KeyboardLayerModifiers,
        isRepeat: Bool,
        at time: TimeInterval
    ) -> Output {
        guard var current = hold else {
            if ownedKeys[keyCode] != nil {
                if isRepeat { return .consume }
                // A new press of a key whose release went missing.
                ownedKeys[keyCode] = nil
            }
            // A trigger held with ⇧⌃⌥⌘ keeps its usual meaning, as in Shift+Tab or ⌘Tab.
            guard !isRepeat, modifiers.isEmpty,
                  let layer = layers.first(where: { $0.triggerKeyCode == keyCode }) else {
                return .pass
            }
            hold = Hold(layer: layer, downAt: time)
            return .consume
        }

        let layer = current.layer
        if keyCode == layer.triggerKeyCode {
            if isRepeat { return .consume }
            // A second press without a release in between: start over.
            for key in current.buffered { ownedKeys[key.chord.keyCode] = .swallow }
            endHold()
            hold = Hold(layer: layer, downAt: time)
            return .consume
        }

        if let role = ownedKeys[keyCode] {
            if isRepeat {
                if case .resend(let chord) = role {
                    return Output(consumesEvent: true, effects: [.send(chord)])
                }
                return .consume
            }
            ownedKeys[keyCode] = nil
        }

        if current.buffered.contains(where: { $0.chord.keyCode == keyCode }) {
            // Holding a buffered key until it repeats is a deliberate layer press.
            let effects = resolveBufferedAsActions(&current)
            hold = current
            return Output(consumesEvent: true, effects: effects)
        }

        // A key held since before the trigger keeps repeating as usual.
        if isRepeat { return .pass }

        let chord = KeyboardLayerChord(keyCode: keyCode, modifiers: modifiers)
        // In a Hyper layer an unlisted key is a binding that presses ⌃⌥⇧⌘ + key.
        let hyper = KeyboardLayerKey(keyCode: keyCode, modifiers: .hyper, keyLabel: "")
        if let action = layer.bindings[chord] ?? (layer.sendsHyperForUnboundKeys ? .sendShortcut(hyper) : nil) {
            let mayBeTyping = !current.used && time - current.downAt < Self.holdThreshold
            if mayBeTyping {
                current.buffered.append(BufferedKey(chord: chord, action: action))
                hold = current
                return .consume
            }
            var effects = resolveBufferedAsActions(&current)
            effects += fire(action, keyCode: keyCode, hold: &current)
            hold = current
            return Output(consumesEvent: true, effects: effects)
        }

        // After an action, unassigned keys type as usual and the layer stays on.
        if current.used { return .pass }

        // An unassigned key before any action means the user was typing: type the trigger and
        // anything held back, then let this key through after them.
        let effects = typingReplay(current, at: time)
        ownedKeys[layer.triggerKeyCode] = .swallow
        endHold()
        return Output(consumesEvent: false, effects: effects)
    }

    mutating func keyUp(_ keyCode: UInt16, at time: TimeInterval) -> Output {
        if var current = hold {
            if keyCode == current.layer.triggerKeyCode {
                var effects: [Effect] = []
                if !current.buffered.isEmpty {
                    // The trigger went up first, so the keys pressed with it were typing.
                    effects = typingReplay(current, at: time)
                } else if !current.used, time - current.downAt < Self.tapLimit {
                    effects = [tapEffect(for: current.layer)]
                }
                endHold()
                return Output(consumesEvent: true, effects: effects)
            }
            if current.buffered.contains(where: { $0.chord.keyCode == keyCode }) {
                // Pressed and released while the trigger is still down: a layer press.
                let effects = resolveBufferedAsActions(&current)
                hold = current
                ownedKeys[keyCode] = nil
                return Output(consumesEvent: true, effects: effects)
            }
        }
        if ownedKeys.removeValue(forKey: keyCode) != nil { return .consume }
        return .pass
    }

    private func tapEffect(for layer: Layer) -> Effect {
        layer.tapsCapsLock ? .toggleCapsLock : .replay(KeyboardLayerChord(keyCode: layer.triggerKeyCode))
    }

    /// The trigger's own key (unless it was held so long it reads as a cancelled layer), then
    /// the keys held back, in the order they were pressed.
    private mutating func typingReplay(_ current: Hold, at time: TimeInterval) -> [Effect] {
        var effects: [Effect] = []
        if time - current.downAt < Self.tapLimit {
            effects.append(tapEffect(for: current.layer))
        }
        for key in current.buffered {
            effects.append(.replay(key.chord))
            ownedKeys[key.chord.keyCode] = .swallow
        }
        return effects
    }

    private mutating func resolveBufferedAsActions(_ current: inout Hold) -> [Effect] {
        var effects: [Effect] = []
        for key in current.buffered {
            effects += fire(key.action, keyCode: key.chord.keyCode, hold: &current)
        }
        current.buffered.removeAll()
        return effects
    }

    private mutating func fire(_ action: KeyboardLayerAction, keyCode: UInt16, hold current: inout Hold) -> [Effect] {
        current.used = true
        if case .sendShortcut(let shortcut) = action {
            ownedKeys[keyCode] = .resend(shortcut.chord)
            return [.send(shortcut.chord)]
        }
        ownedKeys[keyCode] = .swallow
        return [.run(action)]
    }

    /// Ends the layer. Keys still down stop repeating their shortcut; their release is still
    /// consumed.
    private mutating func endHold() {
        hold = nil
        for (keyCode, role) in ownedKeys where role != .swallow {
            ownedKeys[keyCode] = .swallow
        }
    }
}
