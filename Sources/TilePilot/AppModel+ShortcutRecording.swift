import AppKit

@MainActor
extension AppModel {
    func beginShortcutRecording(for featureID: FeatureControlID) {
        stopShortcutRecording()
        prepareWindowForShortcutRecording()
        recordingFeatureID = featureID
        recordingShortcutStableKey = nil

        shortcutRecordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard self.recordingFeatureID == featureID else { return event }
            let consumed = self.handleRecordedShortcutEvent(event, for: featureID)
            return consumed ? nil : event
        }

        shortcutGlobalRecordMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            Task { @MainActor in
                guard self.recordingFeatureID == featureID else { return }
                _ = self.handleRecordedShortcutEvent(event, for: featureID)
            }
        }
    }

    func beginShortcutRecording(for entry: ShortcutEntry) {
        stopShortcutRecording()
        prepareWindowForShortcutRecording()
        recordingFeatureID = nil
        recordingShortcutStableKey = entry.stableKey

        shortcutRecordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard self.recordingShortcutStableKey == entry.stableKey else { return event }
            let consumed = self.handleRecordedShortcutEvent(event, for: entry)
            return consumed ? nil : event
        }

        shortcutGlobalRecordMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            Task { @MainActor in
                guard self.recordingShortcutStableKey == entry.stableKey else { return }
                _ = self.handleRecordedShortcutEvent(event, for: entry)
            }
        }
    }

    func stopShortcutRecording() {
        if let monitor = shortcutRecordMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = shortcutGlobalRecordMonitor {
            NSEvent.removeMonitor(monitor)
        }
        shortcutRecordMonitor = nil
        shortcutGlobalRecordMonitor = nil
        recordingFeatureID = nil
        recordingShortcutStableKey = nil
    }

    private func prepareWindowForShortcutRecording() {
        NSApp.activate(ignoringOtherApps: true)
        let targetWindow = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
        targetWindow?.makeKeyAndOrderFront(nil)
        targetWindow?.makeFirstResponder(nil)
    }

    private func handleRecordedShortcutEvent(_ event: NSEvent, for featureID: FeatureControlID) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 53 {
            stopShortcutRecording()
            return true
        }

        guard let combo = recordedShortcutCombo(from: event) else {
            return false
        }
        assignShortcut(combo: combo, to: featureID)
        stopShortcutRecording()
        return true
    }

    private func handleRecordedShortcutEvent(_ event: NSEvent, for entry: ShortcutEntry) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 53 {
            stopShortcutRecording()
            return true
        }

        guard let combo = recordedShortcutCombo(from: event) else {
            return false
        }
        assignShortcut(combo: combo, to: entry)
        stopShortcutRecording()
        return true
    }

    private func recordedShortcutCombo(from event: NSEvent) -> String? {
        guard let keyToken = skhdKeyToken(for: event.keyCode) ?? fallbackKeyToken(from: event) else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [String] = []
        if flags.contains(.control) { modifiers.append("ctrl") }
        if flags.contains(.shift) { modifiers.append("shift") }
        if flags.contains(.option) { modifiers.append("alt") }
        if flags.contains(.command) { modifiers.append("cmd") }
        if flags.contains(.function) { modifiers.append("fn") }

        if modifiers.isEmpty {
            return keyToken
        }
        return "\(modifiers.joined(separator: " + ")) - \(keyToken)"
    }

    private func fallbackKeyToken(from event: NSEvent) -> String? {
        guard let raw = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.count == 1, let scalar = raw.unicodeScalars.first {
            if CharacterSet.alphanumerics.contains(scalar) {
                return raw.lowercased()
            }
            switch raw {
            case "`", "~": return "0x32"
            case "=": return "="
            case "-": return "-"
            case "[": return "["
            case "]": return "]"
            case ";": return ";"
            case "'": return "'"
            case "\\": return "\\"
            case ",": return ","
            case ".": return "."
            case "/": return "/"
            default: return nil
            }
        }
        return nil
    }

    private func skhdKeyToken(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 0: return "a"
        case 1: return "s"
        case 2: return "d"
        case 3: return "f"
        case 4: return "h"
        case 5: return "g"
        case 6: return "z"
        case 7: return "x"
        case 8: return "c"
        case 9: return "v"
        case 11: return "b"
        case 12: return "q"
        case 13: return "w"
        case 14: return "e"
        case 15: return "r"
        case 16: return "y"
        case 17: return "t"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "o"
        case 32: return "u"
        case 33: return "["
        case 34: return "i"
        case 35: return "p"
        case 36: return "return"
        case 37: return "l"
        case 38: return "j"
        case 39: return "'"
        case 40: return "k"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "n"
        case 46: return "m"
        case 47: return "."
        case 48: return "tab"
        case 49: return "space"
        case 50: return "0x32"
        case 51: return "backspace"
        case 52: return "enter"
        case 53: return "escape"
        case 55, 54, 56, 60, 58, 61, 59, 62, 63:
            return nil
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default:
            return nil
        }
    }
}
