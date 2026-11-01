#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class KeyboardLayerEngineTests: XCTestCase {
    private let tab: UInt16 = 48
    private let grave: UInt16 = 50
    private let capsLockTrigger: UInt16 = 79
    private let c: UInt16 = 8
    private let h: UInt16 = 4
    private let k: UInt16 = 40
    private let x: UInt16 = 7

    private let chrome = KeyboardLayerAction.openApp(
        KeyboardLayerApp(bundleID: "com.google.Chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app")
    )
    private let codex = KeyboardLayerAction.openApp(
        KeyboardLayerApp(bundleID: "com.openai.codex", name: "Codex", path: "/Applications/Codex.app")
    )
    private let megamap = KeyboardLayerAction.feature(id: "app.open-megamap", title: "Open MegaMap")
    private let commandK = KeyboardLayerKey(keyCode: 40, modifiers: .command, keyLabel: "K")

    // MARK: Tapping the trigger

    func testQuickTapTypesTheTriggerOnRelease() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        XCTAssertEqual(engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0), .consume)
        XCTAssertEqual(engine.keyUp(tab, at: 0.08), output(consuming: true, [replay(tab)]))
        XCTAssertFalse(engine.isTrackingKeys)
    }

    func testTriggerRepeatsAreSwallowedAndAShortHoldStillTypesOnce() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        XCTAssertEqual(engine.keyDown(tab, modifiers: [], isRepeat: true, at: 0.5), .consume)
        XCTAssertEqual(engine.keyDown(tab, modifiers: [], isRepeat: true, at: 0.55), .consume)
        XCTAssertEqual(engine.keyUp(tab, at: 0.6), output(consuming: true, [replay(tab)]))
    }

    func testHoldingTheTriggerASecondOrMoreAloneTypesNothing() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        XCTAssertEqual(engine.keyUp(tab, at: 1.2), .consume)
        XCTAssertFalse(engine.isTrackingKeys)
    }

    func testCapsLockTapTogglesCapsLock() {
        var engine = makeEngine(capsLockLayer([chord(c): codex]))

        XCTAssertEqual(engine.keyDown(capsLockTrigger, modifiers: [], isRepeat: false, at: 0), .consume)
        XCTAssertEqual(engine.keyUp(capsLockTrigger, at: 0.1), output(consuming: true, [.toggleCapsLock]))
    }

    // MARK: Ordinary combinations

    func testModifiedTriggerKeepsItsUsualMeaning() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        for modifier in [KeyboardLayerModifiers.shift, .control, .option, .command] {
            XCTAssertEqual(engine.keyDown(tab, modifiers: modifier, isRepeat: false, at: 0), .pass)
            XCTAssertEqual(engine.keyDown(tab, modifiers: modifier, isRepeat: true, at: 0.5), .pass)
            XCTAssertEqual(engine.keyUp(tab, at: 0.6), .pass)
        }
        XCTAssertFalse(engine.isTrackingKeys)
    }

    func testRepeatedCommandTabAllPassesThrough() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        for step in 0..<3 {
            let time = Double(step) * 0.2
            XCTAssertEqual(engine.keyDown(tab, modifiers: .command, isRepeat: false, at: time), .pass)
            XCTAssertEqual(engine.keyUp(tab, at: time + 0.05), .pass)
        }
        // Releasing ⌘ while Tab still repeats must not start the layer.
        XCTAssertEqual(engine.keyDown(tab, modifiers: .command, isRepeat: false, at: 1), .pass)
        XCTAssertEqual(engine.keyDown(tab, modifiers: [], isRepeat: true, at: 1.5), .pass)
        XCTAssertEqual(engine.keyUp(tab, at: 1.6), .pass)
        XCTAssertNil(engine.heldTriggerKeyCode)
    }

    func testOnlyAnIdleTriggerStartsALayer() {
        var engine = makeEngine(tabLayer([chord(c): chrome]), layer(trigger: grave, [chord(c): codex]))

        XCTAssertTrue(engine.startsLayer(tab))
        XCTAssertTrue(engine.startsLayer(grave))
        XCTAssertFalse(engine.startsLayer(c))
        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        XCTAssertFalse(engine.startsLayer(grave))
    }

    func testTriggerPressedDuringAnotherToolsHyperKeyPassesThrough() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        // The tap reports another Hyper Key as ⌃⌥⇧⌘, which leaves Hyper+Tab to that tool.
        XCTAssertEqual(engine.keyDown(tab, modifiers: .hyper, isRepeat: false, at: 0), .pass)
        XCTAssertEqual(engine.keyUp(tab, at: 1.5), .pass)
    }

    // MARK: Deliberate layer presses

    func testBoundKeyAfterAHoldRunsAtOnceAndSwallowsItsRepeats() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.3), output(consuming: true, [.run(chrome)]))
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: true, at: 0.8), .consume)
        XCTAssertEqual(engine.keyUp(c, at: 0.9), .consume)
        XCTAssertEqual(engine.keyUp(tab, at: 1.0), .consume)
        XCTAssertFalse(engine.isTrackingKeys)
    }

    func testReleasingTheTriggerFirstEndsTheLayerAndStillSwallowsTheKey() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        _ = engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.3)
        XCTAssertEqual(engine.keyUp(tab, at: 0.4), .consume)
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: true, at: 0.8), .consume)
        XCTAssertEqual(engine.keyUp(c, at: 0.9), .consume)
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: false, at: 1.0), .pass)
    }

    func testQuickKeyReleasedBeforeTheTriggerIsALayerPress() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.05), .consume)
        XCTAssertEqual(engine.keyUp(c, at: 0.1), output(consuming: true, [.run(chrome)]))
        XCTAssertEqual(engine.keyUp(tab, at: 0.15), .consume)
    }

    func testQuickKeyThatAutoRepeatsIsALayerPress() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        _ = engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.05)
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: true, at: 0.5), output(consuming: true, [.run(chrome)]))
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: true, at: 0.55), .consume)
        XCTAssertEqual(engine.keyUp(c, at: 0.6), .consume)
        XCTAssertEqual(engine.keyUp(tab, at: 0.7), .consume)
    }

    // MARK: Fast typing

    func testRolloverTypesTheTriggerThenTheKey() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.05), .consume)
        XCTAssertEqual(engine.keyUp(tab, at: 0.09), output(consuming: true, [replay(tab), replay(c)]))
        XCTAssertEqual(engine.keyUp(c, at: 0.12), .consume)
        XCTAssertFalse(engine.isTrackingKeys)
    }

    func testSecondQuickBoundKeyWaitsWithTheFirst() {
        var typing = makeEngine(tabLayer([chord(c): chrome, chord(h): megamap]))
        _ = typing.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        _ = typing.keyDown(c, modifiers: [], isRepeat: false, at: 0.05)
        XCTAssertEqual(typing.keyDown(h, modifiers: [], isRepeat: false, at: 0.1), .consume)
        XCTAssertEqual(typing.keyUp(tab, at: 0.12), output(consuming: true, [replay(tab), replay(c), replay(h)]))

        var chorded = makeEngine(tabLayer([chord(c): chrome, chord(h): megamap]))
        _ = chorded.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        _ = chorded.keyDown(c, modifiers: [], isRepeat: false, at: 0.05)
        _ = chorded.keyDown(h, modifiers: [], isRepeat: false, at: 0.1)
        XCTAssertEqual(chorded.keyUp(c, at: 0.15), output(consuming: true, [.run(chrome), .run(megamap)]))
        XCTAssertEqual(chorded.keyUp(h, at: 0.16), .consume)
    }

    func testBoundKeyAfterTheHoldThresholdSettlesEarlierQuickKeysAsActions() {
        var engine = makeEngine(tabLayer([chord(c): chrome, chord(h): megamap]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        _ = engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.05)
        XCTAssertEqual(engine.keyDown(h, modifiers: [], isRepeat: false, at: 0.25), output(consuming: true, [.run(chrome), .run(megamap)]))
    }

    func testUnassignedKeyAfterAQuickBoundKeyMeansTyping() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        _ = engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.05)
        XCTAssertEqual(engine.keyDown(x, modifiers: [], isRepeat: false, at: 0.08), output(consuming: false, [replay(tab), replay(c)]))
        XCTAssertEqual(engine.keyUp(tab, at: 0.1), .consume)
        XCTAssertEqual(engine.keyUp(c, at: 0.11), .consume)
        XCTAssertEqual(engine.keyUp(x, at: 0.12), .pass)
        XCTAssertFalse(engine.isTrackingKeys)
    }

    // MARK: Unassigned keys

    func testUnassignedKeyBeforeAnyActionTypesTheTriggerFirstAndEndsTheLayer() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        XCTAssertEqual(engine.keyDown(x, modifiers: [], isRepeat: false, at: 0.3), output(consuming: false, [replay(tab)]))
        XCTAssertNil(engine.heldTriggerKeyCode)
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.35), .pass)
        XCTAssertEqual(engine.keyUp(c, at: 0.4), .pass)
        XCTAssertEqual(engine.keyUp(x, at: 0.45), .pass)
        XCTAssertEqual(engine.keyUp(tab, at: 0.5), .consume)
    }

    func testUnassignedKeyAfterALongHoldTypesOnlyItself() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        XCTAssertEqual(engine.keyDown(x, modifiers: [], isRepeat: false, at: 1.5), .pass)
        XCTAssertEqual(engine.keyUp(tab, at: 1.6), .consume)
    }

    func testUnassignedKeyAfterAnActionTypesAndTheLayerStaysOn() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        _ = engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.3)
        _ = engine.keyUp(c, at: 0.35)
        XCTAssertEqual(engine.keyDown(x, modifiers: [], isRepeat: false, at: 0.5), .pass)
        XCTAssertEqual(engine.keyUp(x, at: 0.55), .pass)
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.6), output(consuming: true, [.run(chrome)]))
    }

    func testKeyHeldSinceBeforeTheTriggerKeepsRepeating() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        XCTAssertEqual(engine.keyDown(x, modifiers: [], isRepeat: true, at: 0.3), .pass)
        XCTAssertEqual(engine.heldTriggerKeyCode, tab)
    }

    func testModifiersMustMatchExactly() {
        var unbound = makeEngine(tabLayer([chord(c): chrome]))
        _ = unbound.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        XCTAssertEqual(unbound.keyDown(c, modifiers: .shift, isRepeat: false, at: 0.3), output(consuming: false, [replay(tab)]))

        var bound = makeEngine(tabLayer([chord(c): chrome, chord(c, .shift): megamap]))
        _ = bound.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        XCTAssertEqual(bound.keyDown(c, modifiers: .shift, isRepeat: false, at: 0.3), output(consuming: true, [.run(megamap)]))
    }

    // MARK: Shortcuts and Hyper

    func testSendShortcutRepeatsWhileTheLayerIsHeldOnly() {
        var engine = makeEngine(tabLayer([chord(k): .sendShortcut(commandK)]))
        let shortcut = KeyboardLayerChord(keyCode: k, modifiers: .command)

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        XCTAssertEqual(engine.keyDown(k, modifiers: [], isRepeat: false, at: 0.3), output(consuming: true, [.send(shortcut)]))
        XCTAssertEqual(engine.keyDown(k, modifiers: [], isRepeat: true, at: 0.8), output(consuming: true, [.send(shortcut)]))
        XCTAssertEqual(engine.keyUp(tab, at: 0.9), .consume)
        XCTAssertEqual(engine.keyDown(k, modifiers: [], isRepeat: true, at: 0.95), .consume)
        XCTAssertEqual(engine.keyUp(k, at: 1.0), .consume)
    }

    func testHyperLayerSendsHyperForUnassignedKeysAndRunsBoundKeysAtOnce() {
        var engine = makeEngine(capsLockLayer([chord(c): codex], sendsHyper: true))
        let hyperX = KeyboardLayerChord(keyCode: x, modifiers: .hyper)

        _ = engine.keyDown(capsLockTrigger, modifiers: [], isRepeat: false, at: 0)
        // No 0.2-second wait in a Hyper layer: every key is a layer key.
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.05), output(consuming: true, [.run(codex)]))
        XCTAssertEqual(engine.keyUp(c, at: 0.1), .consume)
        XCTAssertEqual(engine.keyDown(x, modifiers: [], isRepeat: false, at: 0.15), output(consuming: true, [.send(hyperX)]))
        XCTAssertEqual(engine.keyDown(x, modifiers: [], isRepeat: true, at: 0.6), output(consuming: true, [.send(hyperX)]))
        XCTAssertEqual(engine.keyUp(x, at: 0.65), .consume)
        XCTAssertEqual(engine.keyUp(capsLockTrigger, at: 0.7), .consume)
    }

    func testCapsLockRolloverTogglesCapsLockBeforeTheKey() {
        var engine = makeEngine(capsLockLayer([chord(c): codex]))

        _ = engine.keyDown(capsLockTrigger, modifiers: [], isRepeat: false, at: 0)
        XCTAssertEqual(engine.keyDown(x, modifiers: [], isRepeat: false, at: 0.05), output(consuming: false, [.toggleCapsLock]))
    }

    // MARK: Independent layers

    func testTwoLayersKeepTheirOwnBindingsForTheSameKey() {
        var engine = makeEngine(tabLayer([chord(c): chrome]), layer(trigger: grave, [chord(c): codex]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.3), output(consuming: true, [.run(chrome)]))
        _ = engine.keyUp(c, at: 0.35)
        _ = engine.keyUp(tab, at: 0.4)

        _ = engine.keyDown(grave, modifiers: [], isRepeat: false, at: 1)
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: false, at: 1.3), output(consuming: true, [.run(codex)]))
        _ = engine.keyUp(c, at: 1.35)
        XCTAssertEqual(engine.keyUp(grave, at: 1.4), .consume)
        XCTAssertFalse(engine.isTrackingKeys)
    }

    func testAnotherLayersTriggerInsideAHeldLayerIsAnOrdinaryKey() {
        var engine = makeEngine(tabLayer([chord(c): chrome]), layer(trigger: grave, [chord(c): codex]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        XCTAssertEqual(engine.keyDown(grave, modifiers: [], isRepeat: false, at: 0.3), output(consuming: false, [replay(tab)]))
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.35), .pass)
        XCTAssertEqual(engine.keyUp(grave, at: 0.4), .pass)
    }

    // MARK: Recovery

    func testResetMidHoldLetsEveryKeyThrough() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        engine.reset()
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.3), .pass)
        XCTAssertEqual(engine.keyUp(c, at: 0.35), .pass)
        XCTAssertEqual(engine.keyUp(tab, at: 0.4), .pass)
    }

    func testTriggerThatIsNoLongerDownIsForgotten() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        _ = engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.3)
        _ = engine.keyUp(c, at: 0.35)
        // Secure Input hid the trigger's release.
        engine.forgetReleasedKeys { _ in false }
        XCTAssertNil(engine.heldTriggerKeyCode)
        XCTAssertFalse(engine.isTrackingKeys)
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: false, at: 5), .pass)
    }

    func testKeysStillDownSurviveTheCheck() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))
        let trigger = tab

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        engine.forgetReleasedKeys { $0 == trigger }
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.6), output(consuming: true, [.run(chrome)]))
    }

    func testNewPressOfAKeyWhoseReleaseWentMissingTypesNormally() {
        var engine = makeEngine(tabLayer([chord(c): chrome]))

        _ = engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0)
        _ = engine.keyDown(c, modifiers: [], isRepeat: false, at: 0.3)
        _ = engine.keyUp(tab, at: 0.4)
        XCTAssertEqual(engine.keyDown(c, modifiers: [], isRepeat: false, at: 2), .pass)
        XCTAssertEqual(engine.keyUp(c, at: 2.1), .pass)
    }

    func testWithoutLayersEveryKeyPasses() {
        var engine = KeyboardLayerEngine()

        XCTAssertEqual(engine.keyDown(tab, modifiers: [], isRepeat: false, at: 0), .pass)
        XCTAssertEqual(engine.keyUp(tab, at: 0.1), .pass)
    }

    // MARK: Helpers

    private func makeEngine(_ layers: KeyboardLayerEngine.Layer...) -> KeyboardLayerEngine {
        var engine = KeyboardLayerEngine()
        engine.configure(layers)
        return engine
    }

    private func tabLayer(_ bindings: [KeyboardLayerChord: KeyboardLayerAction]) -> KeyboardLayerEngine.Layer {
        layer(trigger: tab, bindings)
    }

    private func capsLockLayer(_ bindings: [KeyboardLayerChord: KeyboardLayerAction], sendsHyper: Bool = false) -> KeyboardLayerEngine.Layer {
        layer(trigger: capsLockTrigger, tapsCapsLock: true, sendsHyper: sendsHyper, bindings)
    }

    private func layer(
        trigger: UInt16,
        tapsCapsLock: Bool = false,
        sendsHyper: Bool = false,
        _ bindings: [KeyboardLayerChord: KeyboardLayerAction]
    ) -> KeyboardLayerEngine.Layer {
        KeyboardLayerEngine.Layer(
            id: UUID(),
            triggerKeyCode: trigger,
            tapsCapsLock: tapsCapsLock,
            sendsHyperForUnboundKeys: sendsHyper,
            bindings: bindings
        )
    }

    private func chord(_ keyCode: UInt16, _ modifiers: KeyboardLayerModifiers = []) -> KeyboardLayerChord {
        KeyboardLayerChord(keyCode: keyCode, modifiers: modifiers)
    }

    private func replay(_ keyCode: UInt16) -> KeyboardLayerEngine.Effect {
        .replay(KeyboardLayerChord(keyCode: keyCode))
    }

    private func output(consuming: Bool, _ effects: [KeyboardLayerEngine.Effect]) -> KeyboardLayerEngine.Output {
        KeyboardLayerEngine.Output(consumesEvent: consuming, effects: effects)
    }
}
#endif
