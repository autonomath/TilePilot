import AppKit
import SwiftUI

/// Hold a trigger key and press another key to run an action. Each trigger has its own keys.
struct KeyboardLayersCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var layerPendingRemoval: KeyboardLayer?

    var body: some View {
        let featureMenu = model.keyboardLayerFeatureMenu
        let featureTitles = Dictionary(
            featureMenu.flatMap(\.features).map { ($0.id.rawValue, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        let runningApps = model.keyboardLayerRunningApps

        VStack(alignment: .leading, spacing: 8) {
            header

            Text("Hold a trigger key, such as Tab, then press a second key to run its action. Tapping the trigger alone still types it. These keys are separate from your shortcuts in Actions & Shortcuts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            statusMessages

            ForEach(model.keyboardLayers) { layer in
                KeyboardLayerEditor(
                    layer: layer,
                    featureMenu: featureMenu,
                    featureTitles: featureTitles,
                    runningApps: runningApps,
                    onRemove: { layerPendingRemoval = layer }
                )
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .task {
            while !Task.isCancelled {
                model.refreshKeyboardLayerEnvironment()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog(
            "Remove the \(layerPendingRemoval?.trigger.title ?? "") layer?",
            isPresented: Binding(
                get: { layerPendingRemoval != nil },
                set: { if !$0 { layerPendingRemoval = nil } }
            ),
            presenting: layerPendingRemoval
        ) { layer in
            Button("Remove Layer", role: .destructive) {
                model.removeKeyboardLayer(layer.id)
            }
        } message: { _ in
            Text("Its keys are removed with it.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 5) {
                Label("Keyboard Layers", systemImage: "keyboard")
                    .font(.subheadline.weight(.semibold))
                ContextHelpButton(topic: .keyboardLayers)
            }
            Spacer(minLength: 0)
            Button {
                model.addKeyboardLayer()
            } label: {
                Label("Add Layer", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var statusMessages: some View {
        if let status = model.keyboardLayerStatusMessage {
            HStack(spacing: 8) {
                Label(status.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if status.offersAccessibilitySettings {
                    Button("Open Accessibility Settings") {
                        model.openAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                Spacer(minLength: 0)
            }
        }
        if let message = model.keyboardLayerMessage {
            Label(message, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct KeyboardLayerEditor: View {
    @EnvironmentObject private var model: AppModel
    let layer: KeyboardLayer
    let featureMenu: [(group: UnifiedControlGroup, features: [AppModel.FeatureDefinition])]
    let featureTitles: [String: String]
    let runningApps: [KeyboardLayerApp]
    let onRemove: () -> Void

    var body: some View {
        let blockReason = layer.isEnabled ? nil : model.keyboardLayerEnableBlockReason(layer)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("Use the \(layer.trigger.title) layer", isOn: Binding(
                    get: { layer.isEnabled },
                    set: { model.setKeyboardLayerEnabled(layer.id, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(blockReason != nil)
                .help(blockReason ?? (layer.isEnabled ? "Turn this layer off" : "Turn this layer on"))

                Picker("Trigger", selection: Binding(
                    get: { layer.trigger },
                    set: { model.setKeyboardLayerTrigger(layer.id, $0) }
                )) {
                    ForEach(KeyboardLayerTrigger.allCases) { trigger in
                        Text(trigger.title).tag(trigger)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("The key you hold for this layer")

                Toggle("Other keys act as Hyper (⌃⌥⇧⌘)", isOn: Binding(
                    get: { layer.unboundKeys == .sendHyper },
                    set: { model.setKeyboardLayerUnboundKeys(layer.id, $0 ? .sendHyper : .typeNormally) }
                ))
                .toggleStyle(.checkbox)
                .padding(.leading, 6)
                .help("Holding \(layer.trigger.title) and pressing a key not listed below sends ⌃⌥⇧⌘ + that key, like a Hyper Key. Off: those keys type as usual.")

                Spacer(minLength: 0)

                Button(action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove this layer")
                .accessibilityLabel("Remove the \(layer.trigger.title) layer")
            }

            ForEach(model.keyboardLayerIssues(layer), id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(layer.bindings) { binding in
                    KeyboardLayerBindingRow(
                        layer: layer,
                        binding: binding,
                        featureMenu: featureMenu,
                        featureTitles: featureTitles,
                        runningApps: runningApps
                    )
                }
            }

            Button {
                model.addKeyboardLayerBinding(layer.id)
            } label: {
                Label("Add Key", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
        )
    }
}

private struct KeyboardLayerBindingRow: View {
    @EnvironmentObject private var model: AppModel
    let layer: KeyboardLayer
    let binding: KeyboardLayerBinding
    let featureMenu: [(group: UnifiedControlGroup, features: [AppModel.FeatureDefinition])]
    let featureTitles: [String: String]
    let runningApps: [KeyboardLayerApp]

    private var keyTarget: KeyboardLayerRecordingTarget {
        .key(layerID: layer.id, bindingID: binding.id)
    }

    private var outputTarget: KeyboardLayerRecordingTarget {
        .output(layerID: layer.id, bindingID: binding.id)
    }

    private var outputKey: KeyboardLayerKey? {
        if case .sendShortcut(let key)? = binding.action { return key }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Hold \(layer.trigger.symbol) +")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
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

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                actionMenu

                if outputKey != nil || model.keyboardLayerRecordingTarget == outputTarget {
                    ShortcutRecorderField(
                        symbols: outputKey?.symbols ?? "",
                        spelledOut: outputKey?.spelledOut,
                        isRecording: model.keyboardLayerRecordingTarget == outputTarget,
                        onRecord: { model.beginKeyboardLayerRecording(outputTarget) },
                        onCancelRecording: { model.stopShortcutRecording() },
                        width: 120
                    )
                }

                TextField("Description", text: Binding(
                    get: { binding.note ?? "" },
                    set: { model.setKeyboardLayerBindingNote($0, layerID: layer.id, bindingID: binding.id) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, maxWidth: .infinity)
                .help("What this key is for")

                Button {
                    model.removeKeyboardLayerBinding(layer.id, binding.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove this key")
                .accessibilityLabel("Remove this key")
            }

            if let issue = model.keyboardLayerBindingIssue(binding, in: layer, featureTitles: featureTitles) {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 38)
            }
        }
    }

    private var actionMenu: some View {
        Menu {
            ForEach(featureMenu, id: \.group) { section in
                Menu(section.group.title) {
                    ForEach(section.features, id: \.id) { feature in
                        Button(feature.title) {
                            model.setKeyboardLayerAction(
                                .feature(id: feature.id.rawValue, title: feature.title),
                                layerID: layer.id,
                                bindingID: binding.id
                            )
                        }
                    }
                }
            }
            Divider()
            Menu("Open App") {
                ForEach(runningApps, id: \.path) { app in
                    Button(app.name) {
                        model.setKeyboardLayerAction(.openApp(app), layerID: layer.id, bindingID: binding.id)
                    }
                }
                if !runningApps.isEmpty { Divider() }
                Button("Choose App…") {
                    model.chooseKeyboardLayerApp(layerID: layer.id, bindingID: binding.id)
                }
            }
            Button("Send Shortcut…") {
                model.beginKeyboardLayerRecording(outputTarget)
            }
        } label: {
            Text(actionTitle)
                .lineLimit(1)
        }
        .fixedSize()
        .help("What this key does")
    }

    private var actionTitle: String {
        if outputKey != nil || model.keyboardLayerRecordingTarget == outputTarget { return "Send Shortcut" }
        let title = model.keyboardLayerActionTitle(binding.action, featureTitles: featureTitles)
        return title.count > 44 ? String(title.prefix(43)) + "…" : title
    }
}
