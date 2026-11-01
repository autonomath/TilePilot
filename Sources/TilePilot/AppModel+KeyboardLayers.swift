import AppKit
import Carbon.HIToolbox
import Foundation
import UniformTypeIdentifiers

enum KeyboardLayerRecordingTarget: Equatable {
    /// The key pressed with the trigger.
    case key(layerID: UUID, bindingID: UUID)
    /// The shortcut a Send Shortcut binding presses.
    case output(layerID: UUID, bindingID: UUID)

    var layerID: UUID {
        switch self {
        case .key(let layerID, _), .output(let layerID, _): return layerID
        }
    }

    var bindingID: UUID {
        switch self {
        case .key(_, let bindingID), .output(_, let bindingID): return bindingID
        }
    }
}

struct KeyboardLayerRuntimeStatus: Equatable {
    var tapState: KeyboardLayerEventTap.State = .off
    var accessibilityTrusted = true
    /// The app holding Secure Input, or nil when it's off.
    var secureInputApp: String?
    var capsLockOwner: CapsLockOwner?
    var capsLockRemapFailed = false
}

extension KeyboardLayerApp {
    /// The app's current location: its saved path, or wherever its bundle ID lives now.
    var resolvedURL: URL? {
        if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        guard let bundleID else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}

@MainActor
extension AppModel {
    static let keyboardLayersDefaultsKey = "TilePilot.keyboardLayers"
    static let keyboardLayersCapsLockRemapAppliedDefaultsKey = "TilePilot.keyboardLayers.capsLockRemapApplied"

    static func loadKeyboardLayers() -> [KeyboardLayer] {
        guard let data = UserDefaults.standard.data(forKey: keyboardLayersDefaultsKey),
              let layers = try? JSONDecoder().decode([KeyboardLayer].self, from: data) else {
            return []
        }
        return layers
    }

    /// Whether some layer is on and has a finished key, so the tap should run.
    var keyboardLayersWanted: Bool {
        keyboardLayers.contains { $0.isEnabled && $0.hasUsableBinding }
    }

    /// Whether the tap should be running, given who owns Caps Lock right now.
    var keyboardLayersExpectTap: Bool {
        let capsLockFree = keyboardLayerStatus.capsLockOwner == nil && !keyboardLayerStatus.capsLockRemapFailed
        return !KeyboardLayerPlanner.activeLayers(keyboardLayers, capsLockAvailable: capsLockFree).isEmpty
    }

    /// Remembered across launches, so a crash can't leave Caps Lock remapped to a key nobody handles.
    var capsLockRemapApplied: Bool {
        get { UserDefaults.standard.bool(forKey: Self.keyboardLayersCapsLockRemapAppliedDefaultsKey) }
        set {
            if newValue {
                UserDefaults.standard.set(true, forKey: Self.keyboardLayersCapsLockRemapAppliedDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.keyboardLayersCapsLockRemapAppliedDefaultsKey)
            }
        }
    }

    // MARK: - Editing

    func addKeyboardLayer() {
        let taken = Set(keyboardLayers.map(\.trigger))
        let trigger = [KeyboardLayerTrigger.tab, .grave, .backslash, .capsLock].first { !taken.contains($0) } ?? .tab
        let layer = KeyboardLayer(
            name: "\(Self.keyboardLayerTriggerName(trigger)) Layer",
            trigger: trigger,
            bindings: [KeyboardLayerBinding()]
        )
        keyboardLayerMessage = nil
        updateKeyboardLayers { $0.append(layer) }
    }

    func removeKeyboardLayer(_ id: UUID) {
        if keyboardLayerRecordingTarget?.layerID == id { stopShortcutRecording() }
        keyboardLayerMessage = nil
        updateKeyboardLayers { $0.removeAll { $0.id == id } }
    }

    func renameKeyboardLayer(_ id: UUID, to name: String) {
        updateKeyboardLayer(id, applyingRuntime: false) { $0.name = name }
    }

    func setKeyboardLayerEnabled(_ id: UUID, _ enabled: Bool) {
        guard let layer = keyboardLayers.first(where: { $0.id == id }) else { return }
        if enabled {
            if layer.trigger == .capsLock { refreshCapsLockOwner() }
            if let reason = keyboardLayerEnableBlockReason(layer) {
                keyboardLayerMessage = reason
                return
            }
        }
        keyboardLayerMessage = nil
        updateKeyboardLayer(id) { $0.isEnabled = enabled }
    }

    func setKeyboardLayerTrigger(_ id: UUID, _ trigger: KeyboardLayerTrigger) {
        if keyboardLayerRecordingTarget?.layerID == id { stopShortcutRecording() }
        if trigger == .capsLock { refreshCapsLockOwner() }
        let others = keyboardLayers
        let capsLockOwner = keyboardLayerStatus.capsLockOwner
        var message: String?
        updateKeyboardLayer(id) { layer in
            // A name nobody edited follows the trigger.
            if layer.name == "\(Self.keyboardLayerTriggerName(layer.trigger)) Layer" {
                layer.name = "\(Self.keyboardLayerTriggerName(trigger)) Layer"
            }
            layer.trigger = trigger
            if layer.isEnabled,
               let reason = KeyboardLayerPlanner.enableBlockReason(for: layer, in: others, capsLockOwner: capsLockOwner) {
                layer.isEnabled = false
                message = reason
            }
        }
        keyboardLayerMessage = message
    }

    func setKeyboardLayerUnboundKeys(_ id: UUID, _ unboundKeys: KeyboardLayerUnboundKeys) {
        updateKeyboardLayer(id) { $0.unboundKeys = unboundKeys }
    }

    func addKeyboardLayerBinding(_ layerID: UUID) {
        updateKeyboardLayer(layerID) { $0.bindings.append(KeyboardLayerBinding()) }
    }

    func removeKeyboardLayerBinding(_ layerID: UUID, _ bindingID: UUID) {
        if keyboardLayerRecordingTarget?.bindingID == bindingID { stopShortcutRecording() }
        updateKeyboardLayer(layerID) { $0.bindings.removeAll { $0.id == bindingID } }
    }

    func setKeyboardLayerAction(_ action: KeyboardLayerAction, layerID: UUID, bindingID: UUID) {
        keyboardLayerMessage = nil
        updateKeyboardLayerBinding(layerID, bindingID) { $0.action = action }
    }

    func chooseKeyboardLayerApp(layerID: UUID, bindingID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the app this key opens."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setKeyboardLayerAction(.openApp(KeyboardLayerApp(url: url)), layerID: layerID, bindingID: bindingID)
    }

    private func updateKeyboardLayers(applyingRuntime: Bool = true, _ change: (inout [KeyboardLayer]) -> Void) {
        var layers = keyboardLayers
        change(&layers)
        guard layers != keyboardLayers else { return }
        keyboardLayers = layers
        let defaults = UserDefaults.standard
        if layers.isEmpty {
            defaults.removeObject(forKey: Self.keyboardLayersDefaultsKey)
        } else if let data = try? JSONEncoder().encode(layers) {
            defaults.set(data, forKey: Self.keyboardLayersDefaultsKey)
        }
        if applyingRuntime { applyKeyboardLayerRuntime() }
    }

    private func updateKeyboardLayer(_ id: UUID, applyingRuntime: Bool = true, _ change: (inout KeyboardLayer) -> Void) {
        updateKeyboardLayers(applyingRuntime: applyingRuntime) { layers in
            guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
            change(&layers[index])
        }
    }

    private func updateKeyboardLayerBinding(_ layerID: UUID, _ bindingID: UUID, _ change: (inout KeyboardLayerBinding) -> Void) {
        updateKeyboardLayer(layerID) { layer in
            guard let index = layer.bindings.firstIndex(where: { $0.id == bindingID }) else { return }
            change(&layer.bindings[index])
        }
    }

    private static func keyboardLayerTriggerName(_ trigger: KeyboardLayerTrigger) -> String {
        switch trigger {
        case .tab: return "Tab"
        case .capsLock: return "Caps Lock"
        case .grave: return "Backtick"
        case .backslash: return "Backslash"
        }
    }

    // MARK: - Recording

    func beginKeyboardLayerRecording(_ target: KeyboardLayerRecordingTarget) {
        stopShortcutRecording()
        keyboardLayerMessage = nil
        keyboardLayerRecordingTarget = target
        startKeyRecordingSession { [weak self] event in
            self?.recordKeyboardLayerKey(event, for: target)
        }
    }

    private func recordKeyboardLayerKey(_ event: NSEvent, for target: KeyboardLayerRecordingTarget) {
        guard let key = KeyboardLayerKey(
            keyCode: event.keyCode,
            modifiers: KeyboardLayerModifiers(event.modifierFlags),
            characters: event.characters(byApplyingModifiers: [])
        ) else {
            keyboardLayerMessage = "That key can't be used. Press another key, or Escape to cancel."
            return
        }
        switch target {
        case .key(let layerID, let bindingID):
            guard let layer = keyboardLayers.first(where: { $0.id == layerID }) else {
                stopShortcutRecording()
                return
            }
            if key.keyCode == layer.trigger.eventKeyCode {
                keyboardLayerMessage = "\(layer.trigger.title) starts this layer, so it can't also be one of its keys. Press another key."
                return
            }
            if let other = layer.bindings.first(where: { $0.id != bindingID && $0.key?.chord == key.chord }) {
                keyboardLayerMessage = "\(layer.trigger.title) + \(key.symbols) already runs \(keyboardLayerActionTitle(other.action, featureTitles: [:])). Press another key."
                return
            }
            stopShortcutRecording()
            keyboardLayerMessage = nil
            updateKeyboardLayerBinding(layerID, bindingID) { $0.key = key }
        case .output(let layerID, let bindingID):
            stopShortcutRecording()
            keyboardLayerMessage = nil
            updateKeyboardLayerBinding(layerID, bindingID) { $0.action = .sendShortcut(key) }
        }
    }

    // MARK: - Runtime

    func startKeyboardLayers() {
        keyboardLayerEventTap.setActionHandler { [weak self] action in
            MainActor.assumeIsolated { self?.runKeyboardLayerAction(action) }
        }
        installKeyboardLayerObservers()
        // Also clears a Caps Lock remap left behind by a crash when no layer needs it.
        applyKeyboardLayerRuntime()
    }

    func stopKeyboardLayers() {
        keyboardLayerReapplyTask?.cancel()
        keyboardLayerReapplyTask = nil
        keyboardLayerEventTap.stop()
        capsLockRemapper.stopWatchingForKeyboards()
        if capsLockRemapApplied {
            capsLockRemapper.removeTilePilotMapping()
            capsLockRemapApplied = false
        }
        for observer in keyboardLayerObservers {
            observer.center.removeObserver(observer.token)
        }
        keyboardLayerObservers.removeAll()
    }

    /// Brings the event tap and the Caps Lock remap in line with the saved layers.
    func applyKeyboardLayerRuntime() {
        var status = keyboardLayerStatus
        status.accessibilityTrusted = AXIsProcessTrusted()
        status.capsLockRemapFailed = false
        let wantsCapsLock = keyboardLayers.contains { $0.isEnabled && $0.trigger == .capsLock && $0.hasUsableBinding }
        var capsLockReady = false
        if wantsCapsLock {
            let owner = capsLockRemapper.currentOwner(tilePilotApplied: capsLockRemapApplied)
            status.capsLockOwner = owner
            // Without the tap, a remapped Caps Lock would do nothing at all.
            if owner == nil, status.accessibilityTrusted {
                capsLockReady = capsLockRemapper.applyTilePilotMapping()
                if capsLockReady { capsLockRemapApplied = true }
                status.capsLockRemapFailed = !capsLockReady
            }
        }
        let active = KeyboardLayerPlanner.activeLayers(keyboardLayers, capsLockAvailable: capsLockReady)
        status.tapState = keyboardLayerEventTap.apply(active)
        if status.tapState != .running { capsLockReady = false }
        if !capsLockReady, capsLockRemapApplied {
            capsLockRemapper.removeTilePilotMapping()
            capsLockRemapApplied = false
        }
        if capsLockReady {
            capsLockRemapper.watchForKeyboards { [weak self] in
                MainActor.assumeIsolated { self?.scheduleKeyboardLayerReapply() }
            }
        } else {
            capsLockRemapper.stopWatchingForKeyboards()
        }
        if status != keyboardLayerStatus { keyboardLayerStatus = status }
    }

    /// Runs with the 30-second health check: turns a paused tap back on, catches Accessibility
    /// being granted or removed, and notices another tool taking or releasing Caps Lock.
    func keyboardLayerHealthCheck() {
        let capsLockLayerOn = keyboardLayers.contains { $0.isEnabled && $0.trigger == .capsLock && $0.hasUsableBinding }
        if capsLockLayerOn,
           capsLockRemapper.currentOwner(tilePilotApplied: capsLockRemapApplied) != keyboardLayerStatus.capsLockOwner {
            applyKeyboardLayerRuntime()
            return
        }
        guard keyboardLayersExpectTap else { return }
        let state = keyboardLayerEventTap.ensureRunning()
        if state != .running || keyboardLayerStatus.tapState != .running {
            applyKeyboardLayerRuntime()
        }
    }

    /// Refreshes what the Keyboard Layers section shows. Runs while the section is visible.
    func refreshKeyboardLayerEnvironment() {
        var status = keyboardLayerStatus
        let previousOwner = status.capsLockOwner
        status.accessibilityTrusted = AXIsProcessTrusted()
        status.secureInputApp = Self.secureInputAppName()
        status.tapState = keyboardLayerEventTap.state
        if keyboardLayers.contains(where: { $0.trigger == .capsLock }) {
            status.capsLockOwner = capsLockRemapper.currentOwner(tilePilotApplied: capsLockRemapApplied)
        } else {
            status.capsLockOwner = nil
        }
        if status != keyboardLayerStatus { keyboardLayerStatus = status }
        let stillNeedsAccessibility = status.tapState == .needsAccessibility && !status.accessibilityTrusted
        let tapOutOfStep = keyboardLayersExpectTap && status.tapState != .running && !stillNeedsAccessibility
        let lostAccessibility = !status.accessibilityTrusted && status.tapState == .running
        let capsLockChanged = previousOwner != status.capsLockOwner
            && keyboardLayers.contains { $0.isEnabled && $0.trigger == .capsLock }
        if tapOutOfStep || lostAccessibility || capsLockChanged { applyKeyboardLayerRuntime() }
    }

    func keyboardLayerEnableBlockReason(_ layer: KeyboardLayer) -> String? {
        KeyboardLayerPlanner.enableBlockReason(
            for: layer,
            in: keyboardLayers,
            capsLockOwner: keyboardLayerStatus.capsLockOwner
        )
    }

    func runKeyboardLayerAction(_ action: KeyboardLayerAction) {
        switch action {
        case .feature(let id, let title):
            let featureID = FeatureControlID(rawValue: id)
            guard featureDefinitions.contains(where: { $0.id == featureID }) else {
                keyboardLayerMessage = "“\(title)” no longer exists. Choose another action for that key."
                return
            }
            runFeatureControl(featureID, source: .keyboardLayer)
        case .openApp(let app):
            guard let url = app.resolvedURL else {
                keyboardLayerMessage = "\(app.name) can't be found. Choose the app again for that key."
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
                guard let error else { return }
                let message = "Couldn't open \(app.name): \(error.localizedDescription)"
                Task { @MainActor in self?.keyboardLayerMessage = message }
            }
        case .sendShortcut:
            // The event tap presses the shortcut itself.
            break
        }
    }

    private func refreshCapsLockOwner() {
        let owner = capsLockRemapper.currentOwner(tilePilotApplied: capsLockRemapApplied)
        if keyboardLayerStatus.capsLockOwner != owner { keyboardLayerStatus.capsLockOwner = owner }
    }

    private func scheduleKeyboardLayerReapply() {
        keyboardLayerReapplyTask?.cancel()
        keyboardLayerReapplyTask = Task { [weak self] in
            // A new keyboard takes a moment before it accepts the remap.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.applyKeyboardLayerRuntime()
        }
    }

    private func installKeyboardLayerObservers() {
        guard keyboardLayerObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        // Held keys can't be trusted across sleep, a lock, or a user switch: their releases may
        // never arrive. Waking and unlocking also restore a remap a keyboard may have dropped.
        let resetOnly: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        let resetAndReapply: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in resetOnly {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardLayerEventTap.reset() }
            }
            keyboardLayerObservers.append((workspace, token))
        }
        for name in resetAndReapply {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.keyboardLayerEventTap.reset()
                    self?.applyKeyboardLayerRuntime()
                }
            }
            keyboardLayerObservers.append((workspace, token))
        }
        let distributed = DistributedNotificationCenter.default()
        let locked = distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardLayerEventTap.reset() }
        }
        let unlocked = distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyboardLayerEventTap.reset()
                self?.applyKeyboardLayerRuntime()
            }
        }
        keyboardLayerObservers.append((distributed, locked))
        keyboardLayerObservers.append((distributed, unlocked))
    }

    private static func secureInputAppName() -> String? {
        guard IsSecureEventInputEnabled() else { return nil }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0,
           let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            return name
        }
        return "another app"
    }

    // MARK: - Presentation

    /// A section-wide problem worth showing, if any.
    var keyboardLayerStatusMessage: (text: String, offersAccessibilitySettings: Bool)? {
        guard keyboardLayersWanted else { return nil }
        let status = keyboardLayerStatus
        if !status.accessibilityTrusted || status.tapState == .needsAccessibility {
            return ("Keyboard layers need Accessibility access for TilePilot.", true)
        }
        if status.tapState == .failed {
            return ("Keyboard layers couldn't start. Turn a layer off and on again, or relaunch TilePilot.", false)
        }
        if let app = status.secureInputApp {
            return ("Secure Input is on in \(app), so keys type normally until it turns off.", false)
        }
        return nil
    }

    /// TilePilot features a key can run, grouped like the Actions & Shortcuts list.
    var keyboardLayerFeatureMenu: [(group: UnifiedControlGroup, features: [FeatureDefinition])] {
        let definitions = featureDefinitions.filter { !$0.isExperimental && $0.group != .experimental }
        return Dictionary(grouping: definitions, by: \.group)
            .map { group, features in
                (group: group, features: features.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
            }
            .sorted { $0.group.sortRank < $1.group.sortRank }
    }

    var keyboardLayerRunningApps: [KeyboardLayerApp] {
        var seen: Set<String> = []
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app -> KeyboardLayerApp? in
                guard let url = app.bundleURL else { return nil }
                let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
                return KeyboardLayerApp(bundleID: app.bundleIdentifier, name: name, path: url.path)
            }
            .filter { seen.insert($0.bundleID ?? $0.path).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func keyboardLayerActionTitle(_ action: KeyboardLayerAction?, featureTitles: [String: String]) -> String {
        switch action {
        case .none:
            return "Choose Action"
        case .feature(let id, let title)?:
            return featureTitles[id] ?? title
        case .openApp(let app)?:
            return "Open \(app.name)"
        case .sendShortcut(let key)?:
            return "Send \(key.symbols)"
        }
    }

    /// Problems with a layer as a whole: why it can't be turned on, why it's paused, or what
    /// else competes for its trigger.
    func keyboardLayerIssues(_ layer: KeyboardLayer) -> [String] {
        var issues: [String] = []
        if layer.isEnabled {
            if layer.trigger == .capsLock, let owner = keyboardLayerStatus.capsLockOwner {
                issues.append("Paused. \(owner.explanation)")
            } else if layer.trigger == .capsLock, keyboardLayerStatus.capsLockRemapFailed {
                issues.append("Paused: TilePilot couldn't remap Caps Lock on this keyboard.")
            } else if !layer.hasUsableBinding {
                issues.append("Add a key and an action to start this layer.")
            }
        } else if let reason = keyboardLayerEnableBlockReason(layer) {
            issues.append(reason)
        }
        let triggerCombo = ShortcutComboIdentity.normalized(layer.trigger.skhdCombo)
        if let entry = shortcutEntries.first(where: { ShortcutComboIdentity.normalized($0.combo) == triggerCombo }) {
            issues.append("Your skhd config also uses \(layer.trigger.title) by itself (line \(entry.sourceLine)), so one of them may not work.")
        }
        return issues
    }

    func keyboardLayerBindingIssue(_ binding: KeyboardLayerBinding, in layer: KeyboardLayer, featureTitles: [String: String]) -> String? {
        if let key = binding.key, key.keyCode == layer.trigger.eventKeyCode {
            return "\(layer.trigger.title) starts this layer, so it can't also run an action. Record another key."
        }
        switch binding.action {
        case .feature(let id, let title)?:
            if featureTitles[id] == nil { return "“\(title)” no longer exists. Choose another action." }
        case .openApp(let app)?:
            if app.resolvedURL == nil { return "\(app.name) can't be found. Choose the app again." }
        default:
            break
        }
        if layer.sendsHyperForUnboundKeys, let key = binding.key, key.modifiers.isEmpty,
           let hidden = hyperShortcutTitle(for: key) {
            return "Replaces ⌃⌥⇧⌘\(key.keyLabel), which runs “\(hidden)”."
        }
        return nil
    }

    /// The skhd shortcut that ⌃⌥⇧⌘ + this key runs, which a binding on the key would hide.
    private func hyperShortcutTitle(for key: KeyboardLayerKey) -> String? {
        guard let combo = ShortcutRecordingKey.combo(
            keyCode: key.keyCode,
            modifiers: [.control, .option, .shift, .command],
            unmodifiedCharacters: key.keyLabel.lowercased()
        ) else { return nil }
        let target = ShortcutComboIdentity.normalized(combo)
        guard let entry = shortcutEntries.first(where: { ShortcutComboIdentity.normalized($0.combo) == target }) else {
            return nil
        }
        return featureDefinition(for: entry)?.title ?? shortcutTitle(entry)
    }
}
