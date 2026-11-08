import AppKit
import Combine
import SwiftUI

private final class KeyboardLayerEditorPanel: NSPanel {
    var onClose: (() -> Void)?

    /// Esc closes the window, even while a text field has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            onClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}

/// The key window: what one layer key does. Opens from the Keyboard Layers card, or with the
/// right button and a key its layer doesn't list yet.
@MainActor
final class KeyboardLayerEditorWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private var cancellables: Set<AnyCancellable> = []
    private var isClosingFromModel = false
    private var shownTarget: KeyboardLayerEditorTarget?

    init(model: AppModel) {
        self.model = model
        let panel = KeyboardLayerEditorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            // Non-activating: macOS won't activate TilePilot for a key press its event tap took,
            // so the panel takes keyboard focus without it, in front of the app you were using.
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.contentMinSize = NSSize(width: 640, height: 440)
        super.init(window: panel)
        panel.delegate = self
        panel.onClose = { [weak model] in model?.closeKeyboardLayerEditor() }

        model.$keyboardLayerEditorTarget
            .receive(on: RunLoop.main)
            .sink { [weak self] target in self?.sync(target) }
            .store(in: &cancellables)
        model.$keyboardLayers
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosingFromModel else { return }
        model.closeKeyboardLayerEditor()
    }

    private func sync(_ target: KeyboardLayerEditorTarget?) {
        guard let window else { return }
        guard let target else {
            shownTarget = nil
            if window.isVisible {
                isClosingFromModel = true
                window.close()
                isClosingFromModel = false
            }
            return
        }
        guard target != shownTarget else { return }
        shownTarget = target
        let wasVisible = window.isVisible
        let frame = window.frame
        // A fresh view for each key, so its search and category start over.
        window.contentViewController = NSHostingController(rootView: KeyboardLayerEditorView(model: model, target: target))
        if wasVisible {
            window.setFrame(frame, display: true)
        } else {
            placeAtPointer(window, size: frame.size)
        }
        updateTitle()
        window.makeKeyAndOrderFront(nil)
        if target.recordsKey {
            model.beginKeyboardLayerRecording(.key(layerID: target.layerID, bindingID: target.bindingID))
        }
    }

    /// Opens with its top-left corner by the pointer, kept on the pointer's screen.
    private func placeAtPointer(_ window: NSWindow, size: NSSize) {
        let pointer = NSEvent.mouseLocation
        guard let visible = (NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)?.visibleFrame else {
            window.center()
            return
        }
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let x = min(max(pointer.x - 24, visible.minX), visible.maxX - width)
        let y = min(max(pointer.y + 24 - height, visible.minY), visible.maxY - height)
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    /// "Right Click + K", or "Right Click + New Key" before the key is recorded.
    private func updateTitle() {
        guard let target = shownTarget,
              let layer = model.keyboardLayers.first(where: { $0.id == target.layerID }) else { return }
        let key = layer.bindings.first { $0.id == target.bindingID }?.key?.symbols ?? "New Key"
        window?.title = "\(layer.trigger.title) + \(key)"
    }
}

/// An action's icon: a symbol, or the app's own icon.
struct KeyboardLayerActionIcon: View {
    let icon: KeyboardLayerPickerItem.Icon

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .foregroundStyle(.secondary)
        case .app(let path):
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}

struct KeyboardLayerEditorView: View {
    @ObservedObject var model: AppModel
    let target: KeyboardLayerEditorTarget

    @State private var category: KeyboardLayerActionCategory = .windows
    @State private var query = ""
    @State private var items: [KeyboardLayerPickerItem] = []
    @State private var installedApps: [KeyboardLayerApp] = []
    @State private var appleShortcuts: [String] = []
    @State private var loadingShortcuts = true
    @FocusState private var searchFocused: Bool
    @FocusState private var draftFocused: Bool

    private var layer: KeyboardLayer? { model.keyboardLayers.first { $0.id == target.layerID } }
    private var binding: KeyboardLayerBinding? { layer?.bindings.first { $0.id == target.bindingID } }
    private var keyTarget: KeyboardLayerRecordingTarget { .key(layerID: target.layerID, bindingID: target.bindingID) }
    private var outputTarget: KeyboardLayerRecordingTarget { .output(layerID: target.layerID, bindingID: target.bindingID) }

    var body: some View {
        Group {
            if let layer, let binding {
                VStack(spacing: 0) {
                    header(layer, binding)
                    Divider()
                    HStack(spacing: 0) {
                        sidebar
                        Divider()
                        VStack(spacing: 0) {
                            searchField
                            Divider()
                            actionList(binding)
                            settingsArea(binding)
                        }
                    }
                    Divider()
                    footer(layer, binding)
                }
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 640, idealWidth: 760, maxWidth: .infinity, minHeight: 440, idealHeight: 520, maxHeight: .infinity)
        .task { await load() }
    }

    // MARK: Top: the key

    private func header(_ layer: KeyboardLayer, _ binding: KeyboardLayerBinding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Hold \(layer.trigger == .rightClick ? Text(Image(systemName: "computermouse")) : Text(layer.trigger.symbol)) +")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .help("Hold \(layer.trigger.title), then press this key")

                ShortcutRecorderField(
                    symbols: binding.key?.symbols ?? "",
                    spelledOut: binding.key?.spelledOut,
                    isRecording: model.keyboardLayerRecordingTarget == keyTarget,
                    onRecord: { model.beginKeyboardLayerRecording(keyTarget) },
                    onCancelRecording: { model.stopShortcutRecording() },
                    width: 120,
                    placeholder: "Record Key"
                )

                TextField("Description", text: Binding(
                    get: { binding.note ?? "" },
                    set: { model.setKeyboardLayerBindingNote($0, layerID: layer.id, bindingID: binding.id) }
                ))
                .textFieldStyle(.roundedBorder)
                .help("What this key is for")

                Button("Remove Key", role: .destructive) {
                    model.removeKeyboardLayerBinding(layer.id, binding.id)
                }
            }
            if let issue = model.keyboardLayerBindingIssue(binding, in: layer, featureTitles: model.keyboardLayerFeatureTitles) {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let message = model.keyboardLayerMessage {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: Left: categories

    private var sidebar: some View {
        List(selection: Binding<KeyboardLayerActionCategory?>(
            get: { query.isEmpty ? category : nil },
            set: { picked in
                guard let picked else { return }
                category = picked
                query = ""
            }
        )) {
            ForEach(KeyboardLayerActionCategory.allCases) { category in
                Label(category.title, systemImage: category.systemImage)
                    .tag(category)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 170)
    }

    // MARK: Right: search, actions, settings

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search actions, apps, and shortcuts", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .padding(10)
    }

    /// The chosen category's sections, or search results grouped by category.
    private var groups: [(title: String, items: [KeyboardLayerPickerItem])] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let rows = items.filter { $0.category == category }
            return category.sections.compactMap { section in
                let sectionRows = rows.filter { $0.section == section }
                // Apple Shortcuts keeps its Refresh button while it's empty.
                guard !sectionRows.isEmpty || section == "Apple Shortcuts" else { return nil }
                return (section, sectionRows)
            }
        }
        let results = KeyboardLayerActionCatalog.search(items, query: trimmed)
        return KeyboardLayerActionCategory.allCases.compactMap { category in
            let rows = results.filter { $0.category == category }
            return rows.isEmpty ? nil : (category.title, rows)
        }
    }

    private func actionList(_ binding: KeyboardLayerBinding) -> some View {
        let groups = groups
        return List {
            ForEach(groups, id: \.title) { group in
                Section {
                    if group.items.isEmpty {
                        Text(loadingShortcuts ? "Loading…" : "No shortcuts found.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(group.items) { item in
                        row(item, binding)
                    }
                } header: {
                    HStack {
                        Text(group.title)
                        Spacer()
                        if group.title == "Apple Shortcuts" {
                            Button("Refresh", action: reloadAppleShortcuts)
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        }
                    }
                }
            }
            if groups.isEmpty {
                Text("Nothing matches “\(query)”.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .id(category)
    }

    private func row(_ item: KeyboardLayerPickerItem, _ binding: KeyboardLayerBinding) -> some View {
        let current = isCurrent(item, binding)
        return Button {
            choose(item)
        } label: {
            HStack(spacing: 8) {
                KeyboardLayerActionIcon(icon: item.icon)
                    .frame(width: 18, height: 18)
                Text(item.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let note = item.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .opacity(current ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    @ViewBuilder
    private func settingsArea(_ binding: KeyboardLayerBinding) -> some View {
        if let draft = model.keyboardLayerEditorDraft {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                switch draft.setting {
                case .url:
                    settingLabel("Address")
                    TextField("example.com", text: draftText)
                        .textFieldStyle(.roundedBorder)
                        .focused($draftFocused)
                case .file, .folder:
                    settingLabel(draft.setting == .folder ? "Folder" : "File")
                    HStack {
                        TextField("Path", text: draftText)
                            .textFieldStyle(.roundedBorder)
                            .focused($draftFocused)
                        Button("Choose…") {
                            model.chooseKeyboardLayerEditorPath(folder: draft.setting == .folder)
                        }
                    }
                case .text, .command:
                    settingLabel(draft.setting == .text ? "Text to type" : "Shell command")
                    TextEditor(text: draftText)
                        .font(draft.setting == .command ? .system(.body, design: .monospaced) : .body)
                        .frame(height: 96)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                        .focused($draftFocused)
                    Text(draft.setting == .text ? "Pastes the text, then puts your clipboard back." : "Runs in zsh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .shortcut:
                    EmptyView()
                }
            }
            .padding([.horizontal, .bottom], 10)
            .id(draft.setting)
            .onAppear { draftFocused = true }
        } else if model.keyboardLayerRecordingTarget == outputTarget || outputKey(binding) != nil {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack(spacing: 8) {
                    settingLabel("Shortcut to send")
                    ShortcutRecorderField(
                        symbols: outputKey(binding)?.symbols ?? "",
                        spelledOut: outputKey(binding)?.spelledOut,
                        isRecording: model.keyboardLayerRecordingTarget == outputTarget,
                        onRecord: { model.beginKeyboardLayerRecording(outputTarget) },
                        onCancelRecording: { model.stopShortcutRecording() },
                        width: 160
                    )
                }
            }
            .padding([.horizontal, .bottom], 10)
        }
    }

    private func settingLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: Bottom: summary

    private func footer(_ layer: KeyboardLayer, _ binding: KeyboardLayerBinding) -> some View {
        HStack(spacing: 10) {
            Text("\(layer.trigger.title) + \(binding.key?.symbols ?? "New Key") → \(actionSummary(binding))")
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Done") {
                model.closeKeyboardLayerEditor()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .help("Done (⌘↩)")
        }
        .padding(12)
    }

    // MARK: Helpers

    private var draftText: Binding<String> {
        Binding(
            get: { model.keyboardLayerEditorDraft?.text ?? "" },
            set: { model.keyboardLayerEditorDraft?.text = $0 }
        )
    }

    private func outputKey(_ binding: KeyboardLayerBinding) -> KeyboardLayerKey? {
        if case .sendShortcut(let key)? = binding.action { return key }
        return nil
    }

    private func actionSummary(_ binding: KeyboardLayerBinding) -> String {
        if let draft = model.keyboardLayerEditorDraft {
            return draft.action.map { model.keyboardLayerActionTitle($0, featureTitles: [:]) } ?? String(draft.setting.title.dropLast())
        }
        if model.keyboardLayerRecordingTarget == outputTarget { return "Send Shortcut" }
        return model.keyboardLayerActionTitle(binding.action, featureTitles: model.keyboardLayerFeatureTitles)
    }

    private func isCurrent(_ item: KeyboardLayerPickerItem, _ binding: KeyboardLayerBinding) -> Bool {
        if let draft = model.keyboardLayerEditorDraft { return item.choice == .setting(draft.setting) }
        if model.keyboardLayerRecordingTarget == outputTarget { return item.choice == .setting(.shortcut) }
        return item.matches(binding.action)
    }

    private func choose(_ item: KeyboardLayerPickerItem) {
        switch item.choice {
        case .action(let action):
            model.setKeyboardLayerAction(action, layerID: target.layerID, bindingID: target.bindingID)
        case .chooseApp:
            model.chooseKeyboardLayerApp(layerID: target.layerID, bindingID: target.bindingID)
        case .setting(let setting):
            model.selectKeyboardLayerEditorSetting(setting)
        }
    }

    /// Built each time the window opens: installed apps and Apple Shortcuts load in the background.
    private func load() async {
        items = model.keyboardLayerPickerItems(installedApps: [], appleShortcuts: [])
        category = KeyboardLayerActionCatalog.category(for: binding?.action, in: items)
        if !target.recordsKey { searchFocused = true }
        async let apps = Task.detached(priority: .userInitiated) {
            KeyboardLayerAppScanner.installedApps(in: KeyboardLayerAppScanner.standardRoots)
        }.value
        async let shortcuts = model.loadAppleShortcutNames()
        installedApps = await apps
        items = model.keyboardLayerPickerItems(installedApps: installedApps, appleShortcuts: appleShortcuts)
        appleShortcuts = await shortcuts
        loadingShortcuts = false
        items = model.keyboardLayerPickerItems(installedApps: installedApps, appleShortcuts: appleShortcuts)
    }

    private func reloadAppleShortcuts() {
        loadingShortcuts = true
        Task {
            appleShortcuts = await model.loadAppleShortcutNames()
            loadingShortcuts = false
            items = model.keyboardLayerPickerItems(installedApps: installedApps, appleShortcuts: appleShortcuts)
        }
    }
}
