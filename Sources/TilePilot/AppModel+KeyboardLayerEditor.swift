import AppKit
import Foundation

/// The key the key window is editing.
struct KeyboardLayerEditorTarget: Equatable {
    let layerID: UUID
    let bindingID: UUID
    /// Comes back to the front when the window closes; nil when it was opened from TilePilot.
    let returnApp: NSRunningApplication?
    /// Add Key: record the key as soon as the window is up.
    var recordsKey = false
}

@MainActor
extension AppModel {
    /// Opens the key window, or moves it to another key after saving what was typed for the
    /// previous one.
    func openKeyboardLayerEditor(layerID: UUID, bindingID: UUID, fromAnotherApp: Bool = false, recordsKey: Bool = false) {
        guard let binding = keyboardLayers.first(where: { $0.id == layerID })?.bindings.first(where: { $0.id == bindingID }) else { return }
        let previous = keyboardLayerEditorTarget
        if previous?.layerID == layerID, previous?.bindingID == bindingID { return }
        let previousDraft = keyboardLayerEditorDraft
        let frontApp = NSWorkspace.shared.frontmostApplication
        let returnApp = previous.map(\.returnApp) ?? (fromAnotherApp && frontApp?.processIdentifier != getpid() ? frontApp : nil)
        keyboardLayerMessage = nil
        keyboardLayerEditorDraft = KeyboardLayerEditorDraft(binding.action)
        keyboardLayerEditorTarget = KeyboardLayerEditorTarget(layerID: layerID, bindingID: bindingID, returnApp: returnApp, recordsKey: recordsKey)
        if let previous { finishKeyboardLayerEditing(previous, draft: previousDraft) }
    }

    /// Done, Esc, or the close button: saves what was typed. A key still without an action is
    /// removed, except in a Right Click layer, which keeps it so right button + that key works
    /// as usual from then on.
    func closeKeyboardLayerEditor() {
        guard let target = keyboardLayerEditorTarget else { return }
        let draft = keyboardLayerEditorDraft
        endKeyboardLayerEditor(target)
        finishKeyboardLayerEditing(target, draft: draft)
    }

    /// Closes the window and brings back the app that was in front before it.
    func endKeyboardLayerEditor(_ target: KeyboardLayerEditorTarget) {
        if keyboardLayerRecordingTarget?.bindingID == target.bindingID { stopShortcutRecording() }
        keyboardLayerEditorDraft = nil
        keyboardLayerEditorTarget = nil
        if let app = target.returnApp, !app.isTerminated { app.activate(options: []) }
    }

    private func finishKeyboardLayerEditing(_ target: KeyboardLayerEditorTarget, draft: KeyboardLayerEditorDraft?) {
        if keyboardLayerRecordingTarget?.bindingID == target.bindingID { stopShortcutRecording() }
        updateKeyboardLayer(target.layerID) { layer in
            guard let index = layer.bindings.firstIndex(where: { $0.id == target.bindingID }) else { return }
            if let draft { layer.bindings[index].action = draft.action }
            let binding = layer.bindings[index]
            if binding.action == nil, binding.key == nil || layer.trigger != .rightClick {
                layer.bindings.remove(at: index)
            }
        }
    }

    /// A settings row: Send Shortcut starts recording; the others edit text in the settings area.
    func selectKeyboardLayerEditorSetting(_ setting: KeyboardLayerActionSetting) {
        guard let target = keyboardLayerEditorTarget, keyboardLayerEditorDraft?.setting != setting else { return }
        // Switching actions saves what was typed.
        if let draft = keyboardLayerEditorDraft {
            updateKeyboardLayerBinding(target.layerID, target.bindingID) { $0.action = draft.action }
        }
        keyboardLayerEditorDraft = nil
        if setting == .shortcut {
            beginKeyboardLayerRecording(.output(layerID: target.layerID, bindingID: target.bindingID))
            return
        }
        if keyboardLayerRecordingTarget?.bindingID == target.bindingID { stopShortcutRecording() }
        let action = keyboardLayers.first { $0.id == target.layerID }?.bindings.first { $0.id == target.bindingID }?.action
        let current = KeyboardLayerEditorDraft(action)
        keyboardLayerEditorDraft = current?.setting == setting ? current : KeyboardLayerEditorDraft(setting: setting)
    }

    func chooseKeyboardLayerEditorPath(folder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = folder
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = folder ? "Choose the folder this key opens." : "Choose the file this key opens."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        keyboardLayerEditorDraft = KeyboardLayerEditorDraft(setting: folder ? .folder : .file, text: url.path)
    }

    /// Right button + a key the Right Click layer doesn't list: adds the key and opens the key
    /// window for it.
    func configureKeyboardLayerKey(layerID: UUID, chord: KeyboardLayerChord, event: CGEvent) {
        guard let layer = keyboardLayers.first(where: { $0.id == layerID }),
              let key = KeyboardLayerKey(
                keyCode: chord.keyCode,
                modifiers: chord.modifiers,
                characters: NSEvent(cgEvent: event)?.characters(byApplyingModifiers: [])
              ) else { return }
        let bindingID: UUID
        if let existing = layer.bindings.first(where: { $0.key?.chord == key.chord }) {
            bindingID = existing.id
        } else {
            let binding = KeyboardLayerBinding(key: key)
            bindingID = binding.id
            updateKeyboardLayer(layerID) { $0.bindings.append(binding) }
        }
        openKeyboardLayerEditor(layerID: layerID, bindingID: bindingID, fromAnotherApp: true)
    }

    /// The key window's rows.
    func keyboardLayerPickerItems(installedApps: [KeyboardLayerApp], appleShortcuts: [String]) -> [KeyboardLayerPickerItem] {
        KeyboardLayerActionCatalog.items(
            features: featureDefinitions
                .filter { !$0.isExperimental }
                .map { KeyboardLayerActionCatalog.Feature(id: $0.id.rawValue, title: $0.title, group: $0.group) },
            runningApps: keyboardLayerRunningApps,
            installedApps: installedApps,
            appleShortcuts: appleShortcuts,
            skhdShortcuts: shortcutEntries.map {
                KeyboardLayerActionCatalog.SkhdShortcut(title: shortcutTitle($0), combo: $0.combo, command: $0.command)
            },
            appExists: { FileManager.default.fileExists(atPath: $0) },
            unmetNote: { keyboardLayerUnmetNote($0) }
        )
    }

    /// Shortcuts from Apple's Shortcuts app, by name.
    func loadAppleShortcutNames() async -> [String] {
        let result = await doctorService.runSupportCommand(ShellCommand("/usr/bin/shortcuts", ["list"], timeout: 5))
        guard result.isSuccess else { return [] }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
