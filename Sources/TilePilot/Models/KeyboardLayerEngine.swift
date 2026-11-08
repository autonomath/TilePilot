import Foundation

/// Decides, key by key, whether a held trigger turns the next keys into layer actions or lets
/// them type. It never touches events itself: the event tap feeds it key presses and carries
/// out the effects it returns, so every transition can be tested without a keyboard.
struct KeyboardLayerEngine: Sendable {
    /// Stands in for the right mouse button, which has no key code. Key codes stop at 127.
    static let rightMouseButton: UInt16 = 0x100

    struct Layer: Equatable, Sendable {
        let id: UUID
        let triggerKeyCode: UInt16
        let tapsCapsLock: Bool
        let sendsHyperForUnboundKeys: Bool
        let bindings: [KeyboardLayerChord: KeyboardLayerAction]
        /// Keys listed without an action. With the mouse trigger they press it for real; any
        /// other unlisted key opens its settings the first time.
        var keysLeftAlone: Set<KeyboardLayerChord> = []

        var triggerIsMouseButton: Bool { triggerKeyCode == KeyboardLayerEngine.rightMouseButton }
    }

    enum Effect: Equatable, Sendable {
        /// Type the trigger itself, or click the mouse trigger: a press and release placed ahead
        /// of the current event.
        case replay(KeyboardLayerChord)
        /// Press the mouse trigger for real and leave it down, ahead of the current event: the
        /// user is dragging or typing with it held, and its own release follows.
        case press(KeyboardLayerChord)
        /// Toggle Caps Lock, the Caps Lock trigger's own job when tapped.
        case toggleCapsLock
        /// Press and release a shortcut: a Send Shortcut binding or ⌃⌥⇧⌘ + key.
        case send(KeyboardLayerChord)
        /// Run a TilePilot feature or open an app.
        case run(KeyboardLayerAction)
        /// Open the settings for a key the mouse trigger's layer doesn't list yet.
        case configure(layerID: UUID, KeyboardLayerChord)
    }

    struct Output: Equatable, Sendable {
        var consumesEvent: Bool
        var effects: [Effect] = []

        static let pass = Output(consumesEvent: false)
        static let consume = Output(consumesEvent: true)
    }

    /// A trigger held at least this long and released alone types nothing.
    static let tapLimit: TimeInterval = 1.0
    /// How far, in points, the mouse trigger can move before any action and still be a click.
    static let dragSlop: Double = 8

    private enum KeyRole: Equatable, Sendable {
        case swallow
        case resend(KeyboardLayerChord)
    }

    private struct Hold: Sendable {
        var layer: Layer
        let downAt: TimeInterval
        var used = false
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
        // A hold whose layer is still there carries on with its new keys, so a key added from
        // the right button mid-hold doesn't leak its release or the button's.
        if let current = hold, let layer = layers.first(where: { $0.id == current.layer.id && $0.triggerKeyCode == current.layer.triggerKeyCode }) {
            hold?.layer = layer
        } else {
            reset()
        }
    }

    mutating func reset() {
        hold = nil
        ownedKeys.removeAll()
    }

    /// Forgets keys that are no longer down, for example when Secure Input or sleep hid their
    /// release. A forgotten trigger ends its layer without typing anything.
    mutating func forgetReleasedKeys(isDown: (UInt16) -> Bool) {
        if let current = hold, !isDown(current.layer.triggerKeyCode) { endHold() }
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
            endHold()
            hold = Hold(layer: layer, downAt: time)
            return .consume
        }

        // The right button pressed during a key layer is an ordinary click.
        if keyCode == Self.rightMouseButton { return .pass }

        if let role = ownedKeys[keyCode] {
            if isRepeat {
                if case .resend(let chord) = role {
                    return Output(consumesEvent: true, effects: [.send(chord)])
                }
                return .consume
            }
            ownedKeys[keyCode] = nil
        }

        // A key held since before the trigger keeps repeating as usual.
        if isRepeat { return .pass }

        let chord = KeyboardLayerChord(keyCode: keyCode, modifiers: modifiers)
        // In a Hyper layer an unlisted key is a binding that presses ⌃⌥⇧⌘ + key.
        let hyper = KeyboardLayerKey(keyCode: keyCode, modifiers: .hyper, keyLabel: "")
        // A listed key acts the moment it goes down, however fast it follows the trigger.
        if let action = layer.bindings[chord] ?? (layer.sendsHyperForUnboundKeys ? .sendShortcut(hyper) : nil) {
            let effects = fire(action, keyCode: keyCode, hold: &current)
            hold = current
            return Output(consumesEvent: true, effects: effects)
        }

        // After an action, unassigned keys type as usual and the layer stays on.
        if current.used { return .pass }

        if layer.triggerIsMouseButton {
            // A key left alone is part of what the user is doing, as in a game's right button + W.
            if layer.keysLeftAlone.contains(chord) { return pressHeldButton(layer) }
            // A key the layer doesn't list yet: open its settings.
            current.used = true
            ownedKeys[keyCode] = .swallow
            hold = current
            return Output(consumesEvent: true, effects: [.configure(layerID: layer.id, chord)])
        }

        // An unassigned key before any action means the user was typing: type the trigger,
        // then let this key through after it.
        let effects = typedTrigger(current, at: time)
        ownedKeys[layer.triggerKeyCode] = .swallow
        endHold()
        return Output(consumesEvent: false, effects: effects)
    }

    mutating func keyUp(_ keyCode: UInt16, at time: TimeInterval) -> Output {
        if let current = hold, keyCode == current.layer.triggerKeyCode {
            let effects = current.used ? [] : typedTrigger(current, at: time)
            endHold()
            return Output(consumesEvent: true, effects: effects)
        }
        if ownedKeys.removeValue(forKey: keyCode) != nil { return .consume }
        return .pass
    }

    /// The mouse moved with the mouse trigger down. Before any action, a short move is still a
    /// click and a longer one is a drag; after an action, moving only points at another window.
    mutating func triggerDragged(distance: Double) -> Output {
        guard let current = hold, current.layer.triggerIsMouseButton else { return .pass }
        if current.used || distance < Self.dragSlop { return .consume }
        return pressHeldButton(current.layer)
    }

    private func tapEffect(for layer: Layer) -> Effect {
        layer.tapsCapsLock ? .toggleCapsLock : .replay(KeyboardLayerChord(keyCode: layer.triggerKeyCode))
    }

    /// The trigger's own key, unless it was held so long it reads as a cancelled layer.
    private func typedTrigger(_ current: Hold, at time: TimeInterval) -> [Effect] {
        time - current.downAt < Self.tapLimit ? [tapEffect(for: current.layer)] : []
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

    /// Presses the held mouse button for real and lets its release through.
    private mutating func pressHeldButton(_ layer: Layer) -> Output {
        endHold()
        return Output(consumesEvent: false, effects: [.press(KeyboardLayerChord(keyCode: layer.triggerKeyCode))])
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
