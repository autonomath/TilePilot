import AppKit
import Foundation

@MainActor
extension AppModel {
    /// Why a built-in action can't run right now, or nil when it can.
    func keyboardLayerUnmetNote(_ requirement: KeyboardLayerRequirement) -> String? {
        switch requirement {
        case .none: return nil
        case .yabai: return canRunYabaiRuntimeCommands ? nil : "Needs yabai running"
        case .scriptingAddition: return canRunScriptingAdditionDesktopActions ? nil : "Needs yabai’s scripting addition"
        }
    }

    func runKeyboardLayerBuiltIn(id: String, title: String) async {
        guard let builtIn = KeyboardLayerActionCatalog.builtIn(id: id) else {
            keyboardLayerMessage = "“\(title)” no longer exists. Choose another action for that key."
            return
        }
        if let note = keyboardLayerUnmetNote(builtIn.requirement) {
            reportKeyboardLayerFailure("\(builtIn.title) didn’t work: \(note).")
            return
        }
        // A key press is user-initiated: keep App Nap from slowing the yabai calls several-fold.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Keyboard layer")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        switch builtIn.work {
        case .yabai(let commands):
            _ = await runKeyboardLayerYabai(commands, title: builtIn.title)
        case .snap(let slot):
            await snapFocusedWindow(to: slot, title: builtIn.title)
        case .goToDesktop(let index):
            focusDesktop(index: index)
        case .moveToDesktop(let space):
            // The desktop follows the window.
            _ = await runKeyboardLayerYabai([["-m", "window", "--space", space], ["-m", "space", "--focus", space]], title: builtIn.title)
        case .keys(let chords):
            for (index, chord) in chords.enumerated() {
                if index > 0 { try? await Task.sleep(for: .milliseconds(200)) }
                keyboardLayerEventTap.send(chord)
            }
        case .systemKey(let key):
            Self.postSystemKey(key)
        case .overview(let arguments, let missionControlArgument):
            if canRunYabaiRuntimeCommands {
                let result = await doctorService.runSupportCommand(yabaiCommand(arguments, timeout: 1.5))
                appendCommandLog(from: result)
                if result.isSuccess { return }
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = missionControlArgument.map { [$0] } ?? []
            openKeyboardLayerApplication(URL(fileURLWithPath: "/System/Applications/Mission Control.app"), configuration, title: builtIn.title)
        case .openSystemApp(let path):
            openKeyboardLayerApplication(URL(fileURLWithPath: path), NSWorkspace.OpenConfiguration(), title: builtIn.title)
        case .process(let path, let arguments):
            let result = await doctorService.runSupportCommand(ShellCommand(path, arguments, timeout: 2))
            appendCommandLog(from: result)
            if !result.isSuccess { reportKeyboardLayerFailure(builtIn.title, result) }
        case .frontApp(let command):
            guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
            switch command {
            case .hide:
                app.hide()
            case .hideOthers:
                for other in NSWorkspace.shared.runningApplications
                where other.activationPolicy == .regular && other.processIdentifier != app.processIdentifier {
                    other.hide()
                }
            case .quit:
                app.terminate()
            }
        }
    }

    /// Runs yabai commands in order and stops at the first failure.
    private func runKeyboardLayerYabai(_ commands: [[String]], title: String) async -> Bool {
        for arguments in commands {
            let result = await doctorService.runSupportCommand(yabaiCommand(arguments, timeout: 1.5))
            appendCommandLog(from: result)
            guard result.isSuccess else {
                reportKeyboardLayerFailure(title, result)
                return false
            }
        }
        return true
    }

    /// Floats the focused window if it's tiled, then places it in `slot` of its Work Area (the
    /// visible screen when there's none), the same way Fill Work Area does.
    private func snapFocusedWindow(to slot: CGRect?, title: String) async {
        await refreshLiveState()
        guard let snapshot = workAreaSnapshot, snapshot.source == .yabai,
              let window = snapshot.windows.first(where: \.focused) else {
            reportKeyboardLayerFailure("\(title) didn’t work: no focused window.")
            return
        }
        if window.isNativeFullscreen {
            reportKeyboardLayerFailure("\(window.app) is in full screen. Exit full screen first.")
            return
        }
        guard let display = snapshot.displays.first(where: { $0.id == window.display }) else {
            reportKeyboardLayerFailure("\(title) didn’t work: the window’s display is unavailable.")
            return
        }
        let layout = snapshot.spaces.first(where: { $0.index == window.space })?.layout?.lowercased() ?? "float"
        if !window.floating && layout != "float" {
            guard await runKeyboardLayerYabai([["-m", "window", String(window.id), "--toggle", "float"]], title: title) else { return }
        }
        let area = resolvedWorkArea(for: display) ?? workAreaVisibleFrame(for: display) ?? workAreaDisplayFrame(for: display)
        let target = WorkAreaGeometry.snapFrame(slot: slot, windowSize: CGSize(width: window.frameW, height: window.frameH), area: area)
        if !(await moveWindowForWorkArea(window, to: target, acceptableArea: area)) {
            reportKeyboardLayerFailure("\(title) didn’t work: \(window.app) didn’t move.")
        }
        Task { await self.refreshLiveState() }
    }

    private func openKeyboardLayerApplication(_ url: URL, _ configuration: NSWorkspace.OpenConfiguration, title: String) {
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            let message = "\(title) didn’t work: \(error.localizedDescription)"
            Task { @MainActor in self?.reportKeyboardLayerFailure(message) }
        }
    }

    func reportKeyboardLayerFailure(_ title: String, _ result: CommandResult) {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        reportKeyboardLayerFailure(detail.isEmpty ? "\(title) didn’t work." : "\(title) didn’t work: \(detail)")
    }

    func reportKeyboardLayerFailure(_ message: String) {
        lastErrorMessage = message
        lastActionMessage = nil
    }

    /// Presses a media, sound, or brightness key (NX_KEYTYPE_*), as the keyboard's own keys do.
    private static func postSystemKey(_ key: Int32) {
        for state in [0xA, 0xB] { // key down, key up
            NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int(key) << 16 | state << 8,
                data2: -1
            )?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
