import AppKit

@MainActor
extension AppModel {
    func beginShortcutRecording(for featureID: FeatureControlID) {
        guard !isSavingConfig else {
            lastErrorMessage = "Wait for the current shortcut to finish saving, then record again."
            lastActionMessage = nil
            return
        }
        stopShortcutRecording()
        recordingFeatureID = featureID
        recordingShortcutStableKey = nil
        startShortcutRecording { [weak self] combo in
            self?.assignShortcut(combo: combo, to: featureID)
        }
    }

    func beginShortcutRecording(for entry: ShortcutEntry) {
        guard !isSavingConfig else {
            lastErrorMessage = "Wait for the current shortcut to finish saving, then record again."
            lastActionMessage = nil
            return
        }
        stopShortcutRecording()
        recordingFeatureID = nil
        recordingShortcutStableKey = entry.stableKey
        startShortcutRecording { [weak self] combo in
            self?.assignShortcut(combo: combo, to: entry)
        }
    }

    func stopShortcutRecording() {
        shortcutRecordingSession?.stop()
        shortcutRecordingSession = nil
        if let monitor = shortcutRecordMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = shortcutGlobalRecordMonitor { NSEvent.removeMonitor(monitor) }
        shortcutRecordMonitor = nil
        shortcutGlobalRecordMonitor = nil
        recordingFeatureID = nil
        recordingShortcutStableKey = nil
    }

    private func startShortcutRecording(assign: @escaping (String) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let targetWindow = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
        targetWindow?.makeKeyAndOrderFront(nil)
        targetWindow?.makeFirstResponder(nil)
        guard let targetWindow else {
            stopShortcutRecording()
            lastErrorMessage = "Open the TilePilot window to record a shortcut."
            lastActionMessage = nil
            return
        }

        lastErrorMessage = nil
        lastActionMessage = nil
        let session = ShortcutRecordingSession()
        shortcutRecordingSession = session
        let capturesGlobalShortcuts = session.start(window: targetWindow) { [weak self] event in
            guard let self else { return }
            if ShortcutRecordingKey.cancelsRecording(keyCode: event.keyCode, modifiers: event.modifierFlags) {
                self.stopShortcutRecording()
                return
            }
            guard let combo = ShortcutRecordingKey.combo(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                unmodifiedCharacters: event.characters(byApplyingModifiers: [])
            ) else {
                self.lastErrorMessage = "That key cannot be recorded. Press another key combination, or Escape to cancel."
                self.lastActionMessage = nil
                return
            }
            // Stop intercepting before an asynchronous save or configuration
            // reload. The key release has already been consumed by the session.
            self.stopShortcutRecording()
            assign(combo)
        } onCancel: { [weak self] in
            self?.stopShortcutRecording()
        }
        if !capturesGlobalShortcuts {
            lastActionMessage = "Recording in TilePilot. Shortcuts already used by other apps may be intercepted; choose an unused combination."
        }
    }
}
