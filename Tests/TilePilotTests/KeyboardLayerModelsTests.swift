#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import TilePilot

final class KeyboardLayerModelsTests: XCTestCase {
    private let chrome = KeyboardLayerAction.openApp(
        KeyboardLayerApp(bundleID: "com.google.Chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app")
    )

    func testLayersRoundTripThroughJSON() throws {
        let layers = [
            KeyboardLayer(
                name: "Tab Layer",
                isEnabled: true,
                trigger: .tab,
                bindings: [
                    binding(keyCode: 8, label: "C", chrome),
                    binding(keyCode: 46, label: "M", .feature(id: "app.open-megamap", title: "Open MegaMap")),
                    binding(keyCode: 4, label: "H", .sendShortcut(KeyboardLayerKey(keyCode: 123, modifiers: [], keyLabel: "←"))),
                    KeyboardLayerBinding(),
                ]
            ),
            KeyboardLayer(name: "Caps", trigger: .capsLock, unboundKeys: .sendHyper),
        ]

        let decoded = try JSONDecoder().decode([KeyboardLayer].self, from: JSONEncoder().encode(layers))

        XCTAssertEqual(decoded, layers)
    }

    func testOnlyLayersThatAreOnAndHaveAFinishedKeyBecomeActive() {
        let off = KeyboardLayer(name: "Off", trigger: .tab, bindings: [binding(keyCode: 8, label: "C", chrome)])
        let unfinished = KeyboardLayer(name: "Unfinished", isEnabled: true, trigger: .grave, bindings: [KeyboardLayerBinding(key: key(8, "C"))])
        let ready = KeyboardLayer(name: "Ready", isEnabled: true, trigger: .backslash, bindings: [binding(keyCode: 8, label: "C", chrome)])

        let active = KeyboardLayerPlanner.activeLayers([off, unfinished, ready], capsLockAvailable: true)

        XCTAssertEqual(active.map(\.id), [ready.id])
        XCTAssertEqual(active.first?.triggerKeyCode, 42)
        XCTAssertEqual(active.first?.bindings[KeyboardLayerChord(keyCode: 8)], chrome)
        XCTAssertTrue(KeyboardLayerPlanner.activeLayers([off, unfinished], capsLockAvailable: true).isEmpty)
    }

    func testFirstLayerWinsADuplicateTrigger() {
        let first = KeyboardLayer(name: "First", isEnabled: true, trigger: .tab, bindings: [binding(keyCode: 8, label: "C", chrome)])
        let second = KeyboardLayer(name: "Second", isEnabled: true, trigger: .tab, bindings: [binding(keyCode: 8, label: "C", chrome)])

        XCTAssertEqual(KeyboardLayerPlanner.activeLayers([first, second], capsLockAvailable: true).map(\.id), [first.id])
    }

    func testCapsLockLayerRunsOnlyWhileCapsLockIsFree() {
        let capsLock = KeyboardLayer(name: "Caps", isEnabled: true, trigger: .capsLock, bindings: [binding(keyCode: 8, label: "C", chrome)])

        let active = KeyboardLayerPlanner.activeLayers([capsLock], capsLockAvailable: true)
        XCTAssertEqual(active.first?.triggerKeyCode, 79)
        XCTAssertEqual(active.first?.tapsCapsLock, true)
        XCTAssertTrue(KeyboardLayerPlanner.activeLayers([capsLock], capsLockAvailable: false).isEmpty)
    }

    func testABindingOnTheTriggerItselfNeverCounts() {
        let layer = KeyboardLayer(name: "Tab", isEnabled: true, trigger: .tab, bindings: [binding(keyCode: 48, label: "⇥", chrome)])

        XCTAssertFalse(layer.hasUsableBinding)
        XCTAssertTrue(KeyboardLayerPlanner.activeLayers([layer], capsLockAvailable: true).isEmpty)
    }

    func testOnlyCapsLockLayersActAsHyper() {
        let tab = KeyboardLayer(name: "Tab", isEnabled: true, trigger: .tab, unboundKeys: .sendHyper, bindings: [binding(keyCode: 8, label: "C", chrome)])
        var capsLock = tab
        capsLock.trigger = .capsLock

        XCTAssertEqual(KeyboardLayerPlanner.activeLayers([tab], capsLockAvailable: true).first?.sendsHyperForUnboundKeys, false)
        XCTAssertEqual(KeyboardLayerPlanner.activeLayers([capsLock], capsLockAvailable: true).first?.sendsHyperForUnboundKeys, true)
    }

    func testEnableIsBlockedByADuplicateTriggerOrAnotherCapsLockOwner() {
        let existing = KeyboardLayer(name: "Apps", isEnabled: true, trigger: .tab)
        let duplicate = KeyboardLayer(name: "More apps", trigger: .tab)
        let capsLock = KeyboardLayer(name: "Caps", trigger: .capsLock)
        let layers = [existing, duplicate, capsLock]

        XCTAssertEqual(
            KeyboardLayerPlanner.enableBlockReason(for: duplicate, in: layers, capsLockOwner: nil),
            "“Apps” already uses Tab. Turn it off or choose another key."
        )
        XCTAssertEqual(
            KeyboardLayerPlanner.enableBlockReason(for: capsLock, in: layers, capsLockOwner: .raycastHyperKey),
            CapsLockOwner.raycastHyperKey.explanation
        )
        XCTAssertNil(KeyboardLayerPlanner.enableBlockReason(for: capsLock, in: layers, capsLockOwner: nil))
        XCTAssertNil(KeyboardLayerPlanner.enableBlockReason(for: existing, in: layers, capsLockOwner: .karabiner))
    }

    func testRecordedKeysGetReadableLabels() {
        XCTAssertEqual(KeyboardLayerKey(keyCode: 8, modifiers: [], characters: "c")?.keyLabel, "C")
        XCTAssertEqual(KeyboardLayerKey(keyCode: 8, modifiers: [.shift, .control], characters: "c")?.symbols, "⌃⇧C")
        XCTAssertEqual(KeyboardLayerKey(keyCode: 8, modifiers: [.command, .option], characters: "c")?.spelledOut, "Option + Command + C")
        XCTAssertEqual(KeyboardLayerKey(keyCode: 48, modifiers: [], characters: "\t")?.keyLabel, "⇥")
        XCTAssertEqual(KeyboardLayerKey(keyCode: 83, modifiers: [], characters: "1")?.keyLabel, "Keypad 1")
        XCTAssertEqual(KeyboardLayerKey(keyCode: 96, modifiers: [], characters: nil)?.keyLabel, "F5")
        XCTAssertNil(KeyboardLayerKey(keyCode: 56, modifiers: [], characters: nil))
    }

    func testOnlyTheFourShortcutModifiersCount() {
        let flags: CGEventFlags = [.maskAlphaShift, .maskSecondaryFn, .maskNumericPad, .maskShift, .maskCommand]

        XCTAssertEqual(KeyboardLayerModifiers(flags), [.shift, .command])
        XCTAssertEqual(KeyboardLayerModifiers.hyper.cgEventFlags, [.maskControl, .maskAlternate, .maskShift, .maskCommand])
        XCTAssertEqual(KeyboardLayerModifiers.hyper.symbols, "⌃⌥⇧⌘")
    }

    private func key(_ keyCode: UInt16, _ label: String) -> KeyboardLayerKey {
        KeyboardLayerKey(keyCode: keyCode, modifiers: [], keyLabel: label)
    }

    private func binding(keyCode: UInt16, label: String, _ action: KeyboardLayerAction) -> KeyboardLayerBinding {
        KeyboardLayerBinding(key: key(keyCode, label), action: action)
    }
}
#endif
