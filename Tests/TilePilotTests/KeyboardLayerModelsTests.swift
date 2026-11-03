#if canImport(XCTest)
import AppKit
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
                isEnabled: true,
                trigger: .tab,
                bindings: [
                    KeyboardLayerBinding(key: key(8, "C"), action: chrome, note: "Browser"),
                    binding(keyCode: 46, label: "M", .feature(id: "app.open-megamap", title: "Open MegaMap")),
                    binding(keyCode: 4, label: "H", .sendShortcut(KeyboardLayerKey(keyCode: 123, modifiers: [], keyLabel: "←"))),
                    KeyboardLayerBinding(),
                ]
            ),
            KeyboardLayer(trigger: .capsLock, unboundKeys: .sendHyper),
        ]

        let decoded = try JSONDecoder().decode([KeyboardLayer].self, from: JSONEncoder().encode(layers))

        XCTAssertEqual(decoded, layers)
    }

    func testLayersSavedBeforeDescriptionsStillLoad() throws {
        let saved = #"[{"id":"6F1C2A10-0000-4000-8000-000000000001","name":"Tab Layer","isEnabled":true,"trigger":"tab","unboundKeys":"typeNormally","bindings":[{"id":"6F1C2A10-0000-4000-8000-000000000002","key":{"keyCode":8,"modifiers":0,"keyLabel":"C"}}]}]"#

        let layers = try JSONDecoder().decode([KeyboardLayer].self, from: Data(saved.utf8))

        XCTAssertEqual(layers.first?.bindings.first?.key?.keyLabel, "C")
        XCTAssertNil(layers.first?.bindings.first?.note)
    }

    func testOnlyLayersThatAreOnAndHaveAFinishedKeyBecomeActive() {
        let off = KeyboardLayer(trigger: .tab, bindings: [binding(keyCode: 8, label: "C", chrome)])
        let unfinished = KeyboardLayer(isEnabled: true, trigger: .grave, bindings: [KeyboardLayerBinding(key: key(8, "C"))])
        let ready = KeyboardLayer(isEnabled: true, trigger: .backslash, bindings: [binding(keyCode: 8, label: "C", chrome)])

        let active = KeyboardLayerPlanner.activeLayers([off, unfinished, ready], capsLockAvailable: true)

        XCTAssertEqual(active.map(\.id), [ready.id])
        XCTAssertEqual(active.first?.triggerKeyCode, 42)
        XCTAssertEqual(active.first?.bindings[KeyboardLayerChord(keyCode: 8)], chrome)
        XCTAssertTrue(KeyboardLayerPlanner.activeLayers([off, unfinished], capsLockAvailable: true).isEmpty)
    }

    func testFirstLayerWinsADuplicateTrigger() {
        let first = KeyboardLayer(isEnabled: true, trigger: .tab, bindings: [binding(keyCode: 8, label: "C", chrome)])
        let second = KeyboardLayer(isEnabled: true, trigger: .tab, bindings: [binding(keyCode: 8, label: "C", chrome)])

        XCTAssertEqual(KeyboardLayerPlanner.activeLayers([first, second], capsLockAvailable: true).map(\.id), [first.id])
    }

    func testCapsLockLayerRunsOnlyWhileCapsLockIsFree() {
        let capsLock = KeyboardLayer(isEnabled: true, trigger: .capsLock, bindings: [binding(keyCode: 8, label: "C", chrome)])

        let active = KeyboardLayerPlanner.activeLayers([capsLock], capsLockAvailable: true)
        XCTAssertEqual(active.first?.triggerKeyCode, 79)
        XCTAssertEqual(active.first?.tapsCapsLock, true)
        XCTAssertTrue(KeyboardLayerPlanner.activeLayers([capsLock], capsLockAvailable: false).isEmpty)
    }

    func testABindingOnTheTriggerItselfNeverCounts() {
        let layer = KeyboardLayer(isEnabled: true, trigger: .tab, bindings: [binding(keyCode: 48, label: "⇥", chrome)])

        XCTAssertFalse(layer.isUsable)
        XCTAssertTrue(KeyboardLayerPlanner.activeLayers([layer], capsLockAvailable: true).isEmpty)
    }

    func testAnyLayerCanBeAHyperKeyWithNoKeysListed() {
        let hyper = KeyboardLayer(isEnabled: true, trigger: .grave, unboundKeys: .sendHyper)

        XCTAssertTrue(hyper.isUsable)
        XCTAssertEqual(KeyboardLayerPlanner.activeLayers([hyper], capsLockAvailable: true).first?.sendsHyperForUnboundKeys, true)
    }

    func testEnableIsBlockedByADuplicateTriggerOrAnotherCapsLockOwner() {
        let existing = KeyboardLayer(isEnabled: true, trigger: .tab)
        let duplicate = KeyboardLayer(trigger: .tab)
        let capsLock = KeyboardLayer(trigger: .capsLock)
        let layers = [existing, duplicate, capsLock]

        XCTAssertEqual(
            KeyboardLayerPlanner.enableBlockReason(for: duplicate, in: layers, capsLockOwner: nil),
            "Another layer already uses Tab. Turn it off or choose another trigger."
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
        XCTAssertEqual(KeyboardLayerModifiers(NSEvent.ModifierFlags([.capsLock, .function, .control, .option])), [.control, .option])
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
