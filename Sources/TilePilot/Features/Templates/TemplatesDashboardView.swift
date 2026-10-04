import SwiftUI
import UniformTypeIdentifiers

struct TemplatesDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTemplateID: UUID?
    @State private var selectedDisplayOptionID = ""
    @State private var selectedImportDisplayID: Int?
    @State private var selectedSlotID: UUID?
    @State private var newAllowedAppDraft = ""
    @State private var renamingTemplateID: UUID?
    @State private var sidebarTemplateNameDraft = ""
    @State private var isDrawingNewSlot = false
    @FocusState private var focusedSidebarRenameTemplateID: UUID?

    private var selectedTemplate: WindowLayoutTemplate? {
        guard let selectedTemplateID else { return nil }
        return model.windowLayoutTemplate(withID: selectedTemplateID)
    }

    private var selectedSlot: WindowLayoutSlot? {
        guard let selectedTemplate, let selectedSlotID else { return nil }
        return selectedTemplate.slots.first(where: { $0.id == selectedSlotID })
    }

    private var selectedSlotNumber: Int? {
        guard let selectedTemplate, let selectedSlotID else { return nil }
        return WindowLayoutTemplate.sortedSlots(selectedTemplate.slots)
            .firstIndex(where: { $0.id == selectedSlotID })
            .map { $0 + 1 }
    }

    private var selectedSlotLayer: Int? {
        guard let selectedTemplate, let selectedSlotID else { return nil }
        return canvasOrderedTemplateSlots(selectedTemplate.slots)
            .firstIndex(where: { $0.id == selectedSlotID })
            .map { $0 + 1 }
    }

    private var importDisabledReason: String? {
        model.currentOverviewTemplateImportDisabledReason(displayID: selectedImportDisplayID)
    }

    private var importDisplayOptions: [TemplateImportDisplayOption] {
        model.overviewTemplateImportDisplayOptions
    }

    private var availableAllowedAppSuggestions: [String] {
        model.availableTemplateAllowedAppSuggestions(excluding: selectedSlot?.allowedApps ?? [])
    }

    private var openTemplateAppPalette: [String] {
        model.availableTemplateAllowedAppSuggestions()
    }

    var body: some View {
        NavigationStack {
            HSplitView {
                templatesSidebar
                    .frame(minWidth: 270, idealWidth: 300, maxWidth: 340)

                templateDetailPane
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
            .navigationTitle("TilePilot")
            .task {
                model.rebuildShortcutPresentationCaches()
                syncDisplaySelectionIfNeeded()
                syncImportDisplaySelectionIfNeeded()
                syncSelectedTemplateIfNeeded()
            }
            .onAppear {
                model.rebuildShortcutPresentationCaches()
                syncDisplaySelectionIfNeeded()
                syncImportDisplaySelectionIfNeeded()
                syncSelectedTemplateIfNeeded()
            }
            .onChange(of: selectedTemplateID) { _ in
                model.stopShortcutRecording()
                selectedSlotID = nil
                newAllowedAppDraft = ""
                isDrawingNewSlot = false
            }
            .onChange(of: selectedSlotID) { _ in
                newAllowedAppDraft = ""
            }
            .onChange(of: model.windowLayoutTemplates.map(\.id)) { _ in
                syncSelectedTemplateIfNeeded()
            }
            .onChange(of: model.availableTemplateDisplayOptions.map(\.id)) { _ in
                syncDisplaySelectionIfNeeded()
            }
            .onChange(of: model.liveStateSnapshot?.displays.map(\.id) ?? []) { _ in
                syncImportDisplaySelectionIfNeeded()
            }
            .onChange(of: focusedSidebarRenameTemplateID) { focusedID in
                if focusedID == nil {
                    commitSidebarTemplateRenameIfNeeded()
                }
            }
            .onDisappear {
                model.stopShortcutRecording()
            }
        }
    }

    private var templatesSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Display Shape", selection: $selectedDisplayOptionID) {
                        ForEach(model.availableTemplateDisplayOptions) { option in
                            Text("\(option.name) (\(Int(option.frameWidth))×\(Int(option.frameHeight)))")
                                .tag(option.id)
                        }
                    }
                    .labelsHidden()

                    HStack(spacing: 10) {
                        Button("New Template") {
                            guard let newID = model.createWindowLayoutTemplate(from: selectedDisplayOptionID) else { return }
                            selectedTemplateID = newID
                            if let template = model.windowLayoutTemplate(withID: newID) {
                                startSidebarRename(for: template)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(selectedDisplayOptionID.isEmpty)

                        Spacer(minLength: 0)

                        InfoBubbleButton(text: "Creates a floating layout template for the selected display shape.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Create Template", systemImage: "plus.rectangle.on.rectangle")
            }

            templateImportCard

            if model.windowLayoutTemplates.isEmpty {
                EmptyStateView(
                    title: "No templates yet",
                    systemImage: "rectangle.3.offgrid",
                    message: "Create one from the current display shape, then draw the window slots you want TilePilot to use."
                )
            } else {
                List(selection: $selectedTemplateID) {
                    ForEach(model.windowLayoutTemplates) { template in
                        TemplateSidebarRow(
                            template: template,
                            isRenaming: renamingTemplateID == template.id,
                            renameDraft: $sidebarTemplateNameDraft,
                            focusedRenameID: $focusedSidebarRenameTemplateID,
                            onRenameStart: {
                                startSidebarRename(for: template)
                            },
                            onRenameCommit: {
                                commitSidebarTemplateRenameIfNeeded()
                            },
                            onDuplicate: {
                                guard let newID = model.duplicateWindowLayoutTemplate(template.id) else { return }
                                selectedTemplateID = newID
                                renamingTemplateID = nil
                            },
                            onDelete: {
                                deleteTemplate(template.id)
                            }
                        )
                            .tag(template.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder
    private var templateDetailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let template = selectedTemplate {
                    templateHeader(for: template)
                    templateCanvasCard(for: template)
                    selectedSlotInspectorCard(for: template)
                    templateUsageCard(for: template)
                } else {
                    EmptyStateView(
                        title: "Select a template",
                        systemImage: "rectangle.3.offgrid",
                        message: "Choose a template from the list, create a new one, or import the current Overview layout to start editing slots."
                    )
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    private var templateImportCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if !importDisplayOptions.isEmpty {
                        Picker("Display", selection: $selectedImportDisplayID) {
                            ForEach(importDisplayOptions) { option in
                                Text("\(option.name) · Desktop \(option.currentDesktopIndex)")
                                    .tag(Optional(option.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }

                    Button("Import Current Desktop") {
                        Task { @MainActor in
                            guard let newID = await model.importCurrentDesktopWindowLayoutTemplate(displayID: selectedImportDisplayID) else { return }
                            selectedTemplateID = newID
                            selectedSlotID = nil
                            renamingTemplateID = nil
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(importDisabledReason != nil)

                    Spacer(minLength: 0)

                    InfoBubbleButton(text: "Imports the currently visible desktop on the selected display using fresh live state and the same normalized layout geometry used by Overview.")
                }

                if let importDisabledReason {
                    Label(importDisabledReason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Import Current Desktop", systemImage: "square.and.arrow.down.on.square")
        }
    }

    private func templateHeader(for template: WindowLayoutTemplate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(template.name)
                .font(.title3.weight(.semibold))

            HStack(spacing: 6) {
                templateMetaChip("\(template.sourceDisplayName)", systemImage: "display")
                templateMetaChip(template.displayShapeKey.description, systemImage: "aspectratio")
                templateMetaChip("\(template.slots.count) slot\(template.slots.count == 1 ? "" : "s")", systemImage: "square.grid.3x1.folder.badge.plus")

                if let disabledReason = model.templateApplyDisabledReason(template) {
                    templateStatusChip(shortTemplateStatusLabel(for: disabledReason), systemImage: "exclamationmark.triangle.fill", tint: .orange)
                } else if model.templateNeedsDisplayAutoFit(template) {
                    templateStatusChip("Auto-Fit Display", systemImage: "arrow.down.right.and.arrow.up.left", tint: .blue)
                } else {
                    templateStatusChip("Matching Display", systemImage: "checkmark.circle.fill", tint: .green)
                }

                Button("Apply Template") {
                    model.applyWindowLayoutTemplate(templateID: template.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(templateApplyDisabled(template))

                Spacer(minLength: 0)

                InfoBubbleButton(text: "Slots with app rules fill first. Any App slots then use the focused window first, followed by the current desktop order. Extra windows stay unchanged.")
            }
        }
    }

    private func templateCanvasCard(for template: WindowLayoutTemplate) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Button("Add Full-Screen Slot") {
                        selectedSlotID = model.addFullScreenWindowLayoutTemplateSlot(templateID: template.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!template.slots.isEmpty)

                    Button("Duplicate Slot") {
                        guard let selectedSlotID,
                              let duplicateID = model.duplicateWindowLayoutTemplateSlot(templateID: template.id, slotID: selectedSlotID) else { return }
                        self.selectedSlotID = duplicateID
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedSlotID == nil)

                    Button("Split Vertically") {
                        splitSelectedSlot(in: template, axis: .vertical)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canSplitSelectedSlot(.vertical))

                    Button("Split Horizontally") {
                        splitSelectedSlot(in: template, axis: .horizontal)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canSplitSelectedSlot(.horizontal))

                    Button("Bring to Front") {
                        guard let selectedSlotID else { return }
                        model.bringWindowLayoutTemplateSlotToFront(templateID: template.id, slotID: selectedSlotID)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedSlotID == nil)

                    Button("Delete Slot", role: .destructive) {
                        guard let selectedSlotID else { return }
                        model.deleteWindowLayoutTemplateSlot(templateID: template.id, slotID: selectedSlotID)
                        self.selectedSlotID = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedSlotID == nil)

                    Spacer(minLength: 0)

                    InfoBubbleButton(text: "Drag empty space to create a slot. Drag a slot to move it. Drag the bottom-right handle to resize it. Split the selected slot vertically or horizontally.")
                }

                TemplateCanvasEditor(
                    template: template,
                    selectedSlotID: $selectedSlotID,
                    isDrawingNewSlot: $isDrawingNewSlot,
                    onAddSlot: { rect in
                        guard let newID = model.addWindowLayoutTemplateSlot(templateID: template.id, rect: rect) else { return nil }
                        return newID
                    },
                    onUpdateSlot: { slotID, rect in
                        model.updateWindowLayoutTemplateSlot(templateID: template.id, slotID: slotID, rect: rect)
                    },
                    onAddAllowedAppToSlot: { slotID, appName in
                        model.addAllowedAppToWindowLayoutTemplateSlot(
                            templateID: template.id,
                            slotID: slotID,
                            appName: appName
                        )
                        selectedSlotID = slotID
                    },
                    onRemoveAllowedAppFromSlot: { slotID, appName in
                        model.removeAllowedAppFromWindowLayoutTemplateSlot(
                            templateID: template.id,
                            slotID: slotID,
                            appName: appName
                        )
                        selectedSlotID = slotID
                    }
                )
                .frame(maxWidth: .infinity)

                if !openTemplateAppPalette.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("Open Apps")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text("Drag onto a slot")
                                .font(.caption)
                                .foregroundStyle(.tertiary)

                            Spacer(minLength: 0)

                            InfoBubbleButton(text: "Drag an app onto a slot to allow that app there.")
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(openTemplateAppPalette, id: \.self) { appName in
                                    TemplateDraggableAppChip(appName: appName)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Template Canvas", systemImage: "rectangle.and.pencil.and.ellipsis")
        }
    }

    private func selectedSlotInspectorCard(for template: WindowLayoutTemplate) -> some View {
        GroupBox {
            if let selectedSlot, let selectedSlotNumber {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        templateMetaChip("Slot \(selectedSlotNumber)", systemImage: "square.on.square")
                        if let selectedSlotLayer {
                            templateMetaChip("Layer \(selectedSlotLayer) / \(template.slots.count)", systemImage: "square.3.layers.3d")
                        }
                        if selectedSlot.allowedApps.isEmpty {
                            templateMetaChip("Any App", systemImage: "app")
                        } else {
                            templateMetaChip("\(selectedSlot.allowedApps.count) allowed", systemImage: "checkmark.circle")
                        }

                        Spacer(minLength: 0)

                        InfoBubbleButton(text: "Leave this empty for Any App. If you add apps here, TilePilot only fills this slot with those app windows.")
                    }

                    HStack(spacing: 8) {
                        Button("Send to Back") {
                            model.sendWindowLayoutTemplateSlotToBack(templateID: template.id, slotID: selectedSlot.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selectedSlotLayer == 1)

                        Button("Backward") {
                            model.moveWindowLayoutTemplateSlotBackward(templateID: template.id, slotID: selectedSlot.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selectedSlotLayer == 1)

                        Button("Forward") {
                            model.moveWindowLayoutTemplateSlotForward(templateID: template.id, slotID: selectedSlot.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selectedSlotLayer == template.slots.count)

                        Button("Bring to Front") {
                            model.bringWindowLayoutTemplateSlotToFront(templateID: template.id, slotID: selectedSlot.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selectedSlotLayer == template.slots.count)

                        Spacer(minLength: 0)
                    }

                    if selectedSlot.allowedApps.isEmpty {
                        Text("Any App")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(selectedSlot.allowedApps, id: \.self) { appName in
                                    TemplateSelectedSlotAllowedAppChip(appName: appName)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    HStack(spacing: 10) {
                        TextField("Add app name", text: $newAllowedAppDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                addAllowedAppDraft(to: template.id, slotID: selectedSlot.id)
                            }

                        Button("Add") {
                            addAllowedAppDraft(to: template.id, slotID: selectedSlot.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newAllowedAppDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if !availableAllowedAppSuggestions.isEmpty {
                            Menu("Add Open App") {
                                ForEach(availableAllowedAppSuggestions, id: \.self) { appName in
                                    Button(appName) {
                                        model.addAllowedAppToWindowLayoutTemplateSlot(
                                            templateID: template.id,
                                            slotID: selectedSlot.id,
                                            appName: appName
                                        )
                                    }
                                }
                            }
                            .menuStyle(.borderedButton)
                            .controlSize(.small)
                        }

                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 10) {
                        Button("Clear Allowed Apps") {
                            clearAllowedApps(from: template.id, slotID: selectedSlot.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selectedSlot.allowedApps.isEmpty)

                        TemplateAllowedAppsRemovalDropTarget {
                            removeAllowedAppFromSelectedSlot(templateID: template.id, slotID: selectedSlot.id, droppedAppName: $0)
                        }

                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a slot to restrict which apps can fill it. Leave a slot empty if it should accept any app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Label("Selected Slot", systemImage: "square.on.square")
        }
    }

    private func templateUsageCard(for template: WindowLayoutTemplate) -> some View {
        let featureID = model.templateFeatureID(for: template)
        let featureRow = model.featureControlRow(forID: featureID)
        let assignedCombo = featureRow?.shortcutEntry?.combo ?? featureRow?.assignedCombo
        let assignedShortcutExists = featureRow?.shortcutEntry != nil
        let isPinned = model.isFeaturePinned(featureID)
        let disabledReason = featureRow?.disabledReason

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let assignedCombo, !assignedCombo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(model.displayShortcutComboSymbols(from: assignedCombo))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(model.displayShortcutComboWords(from: assignedCombo))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("No shortcut")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        if model.recordingFeatureID == featureID {
                            HStack(spacing: 4) {
                                Text("Type Shortcut")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.14), in: Capsule())

                                Button {
                                    model.stopShortcutRecording()
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        } else {
                            if assignedShortcutExists {
                                Button("Clear") {
                                    model.removeShortcut(for: featureID)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Button("Record Shortcut") {
                                model.beginShortcutRecording(for: featureID)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Button("Test") {
                            model.runFeatureControl(featureID, source: .shortcutsUI)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(disabledReason != nil || model.activeActionID != nil)

                        Button(isPinned ? "Unpin" : "Pin") {
                            model.toggleFeaturePinned(featureID)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 8) {
                    Text("Also appears in Actions & Shortcuts → Templates")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                }

                if let disabledReason, !disabledReason.isEmpty {
                    Label(disabledReason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Template Shortcut", systemImage: "keyboard")
        }
    }

    private func templateMetaChip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.10), in: Capsule())
    }

    private func templateStatusChip(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(tint.opacity(0.10), in: Capsule())
    }

    private func templateApplyDisabled(_ template: WindowLayoutTemplate) -> Bool {
        model.templateApplyDisabledReason(template) != nil || template.slots.isEmpty
    }

    private func deleteTemplate(_ templateID: UUID) {
        let templates = model.windowLayoutTemplates
        guard let currentIndex = templates.firstIndex(where: { $0.id == templateID }) else { return }
        let nextSelection = templates.indices.contains(currentIndex + 1)
            ? templates[currentIndex + 1].id
            : templates.indices.contains(currentIndex - 1) ? templates[currentIndex - 1].id : nil
        model.deleteWindowLayoutTemplate(templateID)
        selectedTemplateID = nextSelection
        if renamingTemplateID == templateID {
            renamingTemplateID = nil
            sidebarTemplateNameDraft = ""
        }
    }

    private func syncDisplaySelectionIfNeeded() {
        let options = model.availableTemplateDisplayOptions
        guard !options.isEmpty else {
            selectedDisplayOptionID = ""
            return
        }
        if options.contains(where: { $0.id == selectedDisplayOptionID }) {
            return
        }
        selectedDisplayOptionID = model.currentTemplateTargetDisplayOption()?.id ?? options[0].id
    }

    private func syncImportDisplaySelectionIfNeeded() {
        let options = importDisplayOptions
        guard !options.isEmpty else {
            selectedImportDisplayID = nil
            return
        }
        if let selectedImportDisplayID, options.contains(where: { $0.id == selectedImportDisplayID }) {
            return
        }
        selectedImportDisplayID = model.currentOverviewTemplateImportDisplayID() ?? options[0].id
    }

    private func syncSelectedTemplateIfNeeded() {
        let ids = model.windowLayoutTemplates.map(\.id)
        if let selectedTemplateID, ids.contains(selectedTemplateID) {
            return
        }
        selectedTemplateID = ids.first
    }

    private func canSplitSelectedSlot(_ axis: TemplateSlotSplitAxis) -> Bool {
        guard let selectedSlot else { return false }
        return splitTemplateSlotRect(selectedSlot.normalizedRect, axis: axis) != nil
    }

    private func splitSelectedSlot(in template: WindowLayoutTemplate, axis: TemplateSlotSplitAxis) {
        guard let selectedSlotID else { return }
        let newIDs = model.splitWindowLayoutTemplateSlot(templateID: template.id, slotID: selectedSlotID, axis: axis)
        self.selectedSlotID = newIDs?.first
    }

    private func startSidebarRename(for template: WindowLayoutTemplate) {
        selectedTemplateID = template.id
        renamingTemplateID = template.id
        sidebarTemplateNameDraft = template.name
        focusedSidebarRenameTemplateID = template.id
    }

    private func commitSidebarTemplateRenameIfNeeded() {
        guard let renamingTemplateID,
              let template = model.windowLayoutTemplate(withID: renamingTemplateID) else {
            self.renamingTemplateID = nil
            sidebarTemplateNameDraft = ""
            return
        }

        let trimmed = sidebarTemplateNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            model.renameWindowLayoutTemplate(renamingTemplateID, to: trimmed)
        }
        sidebarTemplateNameDraft = ""
        self.renamingTemplateID = nil
        focusedSidebarRenameTemplateID = nil
        selectedTemplateID = template.id
    }

    private func addAllowedAppDraft(to templateID: UUID, slotID: UUID) {
        let trimmed = newAllowedAppDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.addAllowedAppToWindowLayoutTemplateSlot(
            templateID: templateID,
            slotID: slotID,
            appName: trimmed
        )
        newAllowedAppDraft = ""
    }

    private func clearAllowedApps(from templateID: UUID, slotID: UUID) {
        guard let slot = selectedSlot else { return }
        for appName in slot.allowedApps {
            model.removeAllowedAppFromWindowLayoutTemplateSlot(
                templateID: templateID,
                slotID: slotID,
                appName: appName
            )
        }
    }

    private func removeAllowedAppFromSelectedSlot(templateID: UUID, slotID: UUID, droppedAppName: String) {
        model.removeAllowedAppFromWindowLayoutTemplateSlot(
            templateID: templateID,
            slotID: slotID,
            appName: droppedAppName
        )
    }

    private func shortTemplateStatusLabel(for disabledReason: String) -> String {
        if disabledReason.localizedCaseInsensitiveContains("display shape") {
            return "Display Mismatch"
        }
        if disabledReason.localizedCaseInsensitiveContains("display") {
            return "Display Unavailable"
        }
        if disabledReason.localizedCaseInsensitiveContains("runtime") || disabledReason.localizedCaseInsensitiveContains("unavailable") {
            return "Unavailable"
        }
        return "Needs Attention"
    }
}

private struct TemplateSidebarRow: View {
    let template: WindowLayoutTemplate
    let isRenaming: Bool
    @Binding var renameDraft: String
    @FocusState.Binding var focusedRenameID: UUID?
    let onRenameStart: () -> Void
    let onRenameCommit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if isRenaming {
                    TextField("Template Name", text: $renameDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedRenameID, equals: template.id)
                        .onSubmit {
                            onRenameCommit()
                        }
                } else {
                    Text(template.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }

                Text(template.sourceDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("\(template.slots.count) slot\(template.slots.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Menu {
                Button("Rename") {
                    onRenameStart()
                }
                Button("Duplicate") {
                    onDuplicate()
                }
                Button("Delete", role: .destructive) {
                    onDelete()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 2)
    }
}

private struct TemplateCanvasEditor: View {
    let template: WindowLayoutTemplate
    @Binding var selectedSlotID: UUID?
    @Binding var isDrawingNewSlot: Bool
    let onAddSlot: (CGRect) -> UUID?
    let onUpdateSlot: (UUID, CGRect) -> Void
    let onAddAllowedAppToSlot: (UUID, String) -> Void
    let onRemoveAllowedAppFromSlot: (UUID, String) -> Void

    @State private var creationStartPoint: CGPoint?
    @State private var creationCurrentPoint: CGPoint?
    @State private var movingSlotID: UUID?
    @State private var movingSlotStartRect: CGRect = .zero
    @State private var resizingSlotID: UUID?
    @State private var resizingSlotStartRect: CGRect = .zero
    @State private var dropTargetSlotID: UUID?

    var body: some View {
        GeometryReader { proxy in
            let canvasSize = proxy.size
            let canvasSlots = canvasOrderedTemplateSlots(template.slots)
            let slotNumbers = Dictionary(
                uniqueKeysWithValues: WindowLayoutTemplate.sortedSlots(template.slots).enumerated().map { offset, slot in
                    (slot.id, offset + 1)
                }
            )
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )

                templateCanvasGrid

                ForEach(canvasSlots, id: \.id) { slot in
                    TemplateCanvasSlotView(
                        slot: slot,
                        index: slotNumbers[slot.id] ?? 0,
                        layerIndex: slot.zIndex + 1,
                        canvasSize: canvasSize,
                        isSelected: selectedSlotID == slot.id,
                        isDropTargeted: dropTargetSlotID == slot.id,
                        onRemoveAllowedApp: { appName in
                            onRemoveAllowedAppFromSlot(slot.id, appName)
                        }
                    )
                }

                if let previewRect = creationPreviewRect(in: canvasSize) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        )
                        .frame(width: previewRect.width, height: previewRect.height)
                        .offset(x: previewRect.minX, y: previewRect.minY)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(selectionTapGesture(in: canvasSize))
            .gesture(canvasGesture(in: canvasSize))
            .onDrop(
                of: TemplateAppDragDrop.dropTypeIdentifiers,
                delegate: TemplateCanvasDropDelegate(
                    template: template,
                    canvasSize: canvasSize,
                    hoveredSlotID: $dropTargetSlotID,
                    onDroppedApp: { slotID, appName in
                        onAddAllowedAppToSlot(slotID, appName)
                    }
                )
            )
        }
        .aspectRatio(CGFloat(template.displayShapeKey.aspectRatio), contentMode: .fit)
        .frame(maxWidth: .infinity, minHeight: 340, maxHeight: 560)
    }

    private var templateCanvasGrid: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Path { path in
                let thirdsX = size.width / 3
                let thirdsY = size.height / 3
                for column in 1...2 {
                    let x = CGFloat(column) * thirdsX
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for row in 1...2 {
                    let y = CGFloat(row) * thirdsY
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            .stroke(Color.secondary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
        }
        .allowsHitTesting(false)
    }

    private func canvasGesture(in canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let startPoint = clampedCanvasPoint(value.startLocation, in: canvasSize)
                let currentPoint = clampedCanvasPoint(value.location, in: canvasSize)

                if creationStartPoint == nil, movingSlotID == nil, resizingSlotID == nil {
                    if isDrawingNewSlot {
                        creationStartPoint = startPoint
                        creationCurrentPoint = currentPoint
                        selectedSlotID = nil
                        return
                    }

                    if let resizeTargetID = resizeHandleSlotID(at: startPoint, in: canvasSize),
                       let resizeTarget = template.slots.first(where: { $0.id == resizeTargetID }) {
                        resizingSlotID = resizeTargetID
                        resizingSlotStartRect = resizeTarget.normalizedRect
                        selectedSlotID = resizeTargetID
                        return
                    }

                    if let moveTargetID = slotID(at: startPoint, in: canvasSize),
                       let moveTarget = template.slots.first(where: { $0.id == moveTargetID }) {
                        movingSlotID = moveTargetID
                        movingSlotStartRect = moveTarget.normalizedRect
                        selectedSlotID = moveTargetID
                        return
                    }

                    creationStartPoint = startPoint
                    creationCurrentPoint = currentPoint
                    selectedSlotID = nil
                    return
                }

                if let movingSlotID {
                    let dx = value.translation.width / max(canvasSize.width, 1)
                    let dy = value.translation.height / max(canvasSize.height, 1)
                    let updated = clampedNormalizedTemplateRect(
                        CGRect(
                            x: movingSlotStartRect.minX + dx,
                            y: movingSlotStartRect.minY + dy,
                            width: movingSlotStartRect.width,
                            height: movingSlotStartRect.height
                        )
                    )
                    onUpdateSlot(movingSlotID, updated)
                    return
                }

                if let resizingSlotID {
                    let dx = value.translation.width / max(canvasSize.width, 1)
                    let dy = value.translation.height / max(canvasSize.height, 1)
                    let updated = clampedNormalizedTemplateRect(
                        CGRect(
                            x: resizingSlotStartRect.minX,
                            y: resizingSlotStartRect.minY,
                            width: resizingSlotStartRect.width + dx,
                            height: resizingSlotStartRect.height + dy
                        )
                    )
                    onUpdateSlot(resizingSlotID, updated)
                    return
                }

                creationCurrentPoint = currentPoint
            }
            .onEnded { _ in
                defer {
                    creationStartPoint = nil
                    creationCurrentPoint = nil
                    movingSlotID = nil
                    resizingSlotID = nil
                }

                if movingSlotID != nil || resizingSlotID != nil {
                    return
                }

                guard let start = creationStartPoint,
                      let end = creationCurrentPoint else {
                    return
                }

                guard abs(end.x - start.x) >= 12, abs(end.y - start.y) >= 12 else {
                    if !isDrawingNewSlot {
                        selectedSlotID = nil
                    }
                    return
                }

                let rawRect = CGRect(
                    x: start.x,
                    y: start.y,
                    width: end.x - start.x,
                    height: end.y - start.y
                )
                let normalized = normalizedTemplateRect(from: rawRect, in: canvasSize)
                selectedSlotID = onAddSlot(normalized)
                if isDrawingNewSlot {
                    isDrawingNewSlot = false
                }
            }
    }

    private func selectionTapGesture(in canvasSize: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard !isDrawingNewSlot else { return }
                let point = clampedCanvasPoint(value.location, in: canvasSize)
                if let iconHit = allowedAppHit(at: point, in: canvasSize) {
                    onRemoveAllowedAppFromSlot(iconHit.slotID, iconHit.appName)
                    selectedSlotID = iconHit.slotID
                    return
                }
                selectedSlotID = slotID(at: point, in: canvasSize)
            }
    }

    private func creationPreviewRect(in canvasSize: CGSize) -> CGRect? {
        guard let creationStartPoint, let creationCurrentPoint else { return nil }
        let rawRect = CGRect(
            x: creationStartPoint.x,
            y: creationStartPoint.y,
            width: creationCurrentPoint.x - creationStartPoint.x,
            height: creationCurrentPoint.y - creationStartPoint.y
        )
        guard abs(rawRect.width) >= 4, abs(rawRect.height) >= 4 else { return nil }
        let normalized = normalizedTemplateRect(from: rawRect, in: canvasSize)
        return CGRect(
            x: normalized.minX * canvasSize.width,
            y: normalized.minY * canvasSize.height,
            width: normalized.width * canvasSize.width,
            height: normalized.height * canvasSize.height
        )
    }

    private func clampedCanvasPoint(_ point: CGPoint, in canvasSize: CGSize) -> CGPoint {
        CGPoint(
            x: max(0, min(canvasSize.width, point.x)),
            y: max(0, min(canvasSize.height, point.y))
        )
    }

    private func slotID(at point: CGPoint, in canvasSize: CGSize) -> UUID? {
        for slot in canvasOrderedTemplateSlots(template.slots).reversed() {
            if canvasRect(for: slot, in: canvasSize).contains(point) {
                return slot.id
            }
        }
        return nil
    }

    private func resizeHandleSlotID(at point: CGPoint, in canvasSize: CGSize) -> UUID? {
        let handleSize: CGFloat = 28
        for slot in canvasOrderedTemplateSlots(template.slots).reversed() {
            let rect = canvasRect(for: slot, in: canvasSize)
            let handleRect = CGRect(
                x: rect.maxX - handleSize,
                y: rect.maxY - handleSize,
                width: handleSize,
                height: handleSize
            )
            if handleRect.contains(point) {
                return slot.id
            }
        }
        return nil
    }

    private func allowedAppHit(at point: CGPoint, in canvasSize: CGSize) -> (slotID: UUID, appName: String)? {
        for slot in canvasOrderedTemplateSlots(template.slots).reversed() {
            for hit in visibleAllowedAppRects(for: slot, in: canvasSize) {
                if hit.rect.contains(point) {
                    return (slot.id, hit.appName)
                }
            }
        }
        return nil
    }

    private func visibleAllowedAppRects(for slot: WindowLayoutSlot, in canvasSize: CGSize) -> [(appName: String, rect: CGRect)] {
        let visibleApps = Array(slot.allowedApps.prefix(3))
        guard !visibleApps.isEmpty else { return [] }

        let slotRect = canvasRect(for: slot, in: canvasSize)
        let iconSize = TemplateSlotLayoutMetrics.allowedAppIconSize
        let spacing = TemplateSlotLayoutMetrics.allowedAppIconSpacing
        let topPadding = TemplateSlotLayoutMetrics.slotContentPadding
        let rightPadding = TemplateSlotLayoutMetrics.slotContentPadding
        let totalIconsWidth = CGFloat(visibleApps.count) * iconSize + CGFloat(max(0, visibleApps.count - 1)) * spacing
        let originX = slotRect.maxX - rightPadding - totalIconsWidth
        let originY = slotRect.minY + topPadding

        return visibleApps.enumerated().map { offset, appName in
            let x = originX + CGFloat(offset) * (iconSize + spacing)
            let rect = CGRect(x: x, y: originY, width: iconSize, height: iconSize)
            return (appName, rect)
        }
    }
}

private struct TemplateCanvasSlotView: View {
    let slot: WindowLayoutSlot
    let index: Int
    let layerIndex: Int
    let canvasSize: CGSize
    let isSelected: Bool
    let isDropTargeted: Bool
    let onRemoveAllowedApp: (String) -> Void

    var body: some View {
        let rect = canvasRect(for: slot, in: canvasSize)

        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundTint)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(borderTint, lineWidth: isSelected || isDropTargeted ? 2.5 : 1.5)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.25), in: Capsule())
                        .foregroundStyle(.white)

                    Spacer(minLength: 0)

                    if !slot.allowedApps.isEmpty {
                        TemplateSlotAllowedAppsStrip(
                            appNames: slot.allowedApps,
                            onRemove: onRemoveAllowedApp
                        )
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)

            Circle()
                .fill(borderTint)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                )
                .padding(8)

            VStack {
                Spacer(minLength: 0)
                HStack {
                    Label("\(layerIndex)", systemImage: "square.3.layers.3d")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.20), in: Capsule())
                        .foregroundStyle(.white.opacity(0.95))
                    Spacer(minLength: 0)
                }
            }
            .padding(8)
        }
        .frame(width: max(28, rect.width), height: max(28, rect.height))
        .offset(x: rect.minX, y: rect.minY)
        .zIndex(Double(slot.zIndex))
        .contentShape(Rectangle())
    }

    private var backgroundTint: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.32)
        }
        return (isSelected ? Color.accentColor : Color.blue).opacity(isSelected ? 0.24 : 0.16)
    }

    private var borderTint: Color {
        if isDropTargeted || isSelected {
            return Color.accentColor
        }
        return Color.blue.opacity(0.85)
    }
}

private struct TemplateCanvasDropDelegate: DropDelegate {
    let template: WindowLayoutTemplate
    let canvasSize: CGSize
    @Binding var hoveredSlotID: UUID?
    let onDroppedApp: (UUID, String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: TemplateAppDragDrop.dropTypeIdentifiers)
    }

    func dropEntered(info: DropInfo) {
        hoveredSlotID = slotID(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        hoveredSlotID = slotID(at: info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        hoveredSlotID = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let targetSlotID = slotID(at: info.location)
        hoveredSlotID = nil
        guard let targetSlotID else { return false }
        return TemplateAppDragDrop.loadAppName(from: info.itemProviders(for: TemplateAppDragDrop.dropTypeIdentifiers)) { appName in
            onDroppedApp(targetSlotID, appName)
        }
    }

    private func slotID(at point: CGPoint) -> UUID? {
        let clampedPoint = CGPoint(
            x: max(0, min(canvasSize.width, point.x)),
            y: max(0, min(canvasSize.height, point.y))
        )
        for slot in canvasOrderedTemplateSlots(template.slots).reversed() {
            if canvasRect(for: slot, in: canvasSize).contains(clampedPoint) {
                return slot.id
            }
        }
        return nil
    }
}

private struct TemplateDraggableAppChip: View {
    let appName: String
    @State private var isHovering = false

    var body: some View {
        Group {
            if let icon = AppIconResolver.shared.icon(forAppNamed: appName, size: 24) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "app")
                    .font(.body.weight(.semibold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(2)
        .background(
            Group {
                if isHovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                }
            }
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .contentShape(Rectangle())
        .onDrag {
            TemplateAppDragDrop.provider(for: appName)
        }
        .help(appName)
    }
}

private struct TemplateAllowedAppsRemovalDropTarget: View {
    let onDroppedApp: (String) -> Void
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
            Text("Drop Here to Remove")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isDropTargeted ? .red : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background((isDropTargeted ? Color.red.opacity(0.10) : Color.secondary.opacity(0.08)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isDropTargeted ? Color.red.opacity(0.6) : Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .onDrop(of: TemplateAppDragDrop.dropTypeIdentifiers, isTargeted: $isDropTargeted) { providers in
            TemplateAppDragDrop.loadAppName(from: providers) { appName in
                onDroppedApp(appName)
            }
        }
    }
}

private struct TemplateSlotAllowedAppsStrip: View {
    let appNames: [String]
    let onRemove: (String) -> Void

    var body: some View {
        HStack(spacing: TemplateSlotLayoutMetrics.allowedAppIconSpacing) {
            if appNames.count > 3 {
                Text("+\(appNames.count - 3)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.25), in: Capsule())
            }

            ForEach(Array(appNames.prefix(3)), id: \.self) { appName in
                TemplateSlotAllowedAppIcon(
                    appName: appName,
                    iconSize: TemplateSlotLayoutMetrics.allowedAppIconSize,
                    onRemove: { onRemove(appName) }
                )
            }
        }
    }
}

private struct TemplateSlotAllowedAppIcon: View {
    let appName: String
    let iconSize: CGFloat
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onRemove) {
            Group {
                Group {
                    if let icon = AppIconResolver.shared.icon(forAppNamed: appName, size: iconSize) {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: iconSize, height: iconSize)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    } else {
                        Image(systemName: "app")
                            .font(.caption.weight(.semibold))
                            .frame(width: iconSize, height: iconSize)
                            .foregroundStyle(.white.opacity(0.9))
                            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(isHovering ? Color.red.opacity(0.55) : Color.clear, lineWidth: 1)
                )
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help("Click to remove \(appName)")
    }
}

private struct TemplateSelectedSlotAllowedAppChip: View {
    let appName: String

    var body: some View {
        HStack(spacing: 6) {
            if let icon = AppIconResolver.shared.icon(forAppNamed: appName, size: 16) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: "app")
                    .font(.caption.weight(.semibold))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
            }

            Text(appName)
                .lineLimit(1)

            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

private enum TemplateSlotLayoutMetrics {
    static let allowedAppIconSize: CGFloat = 32
    static let allowedAppIconSpacing: CGFloat = 4
    static let slotContentPadding: CGFloat = 8
}

private enum TemplateAppDragDrop {
    static let dropTypeIdentifiers = [
        UTType.utf8PlainText.identifier,
        UTType.plainText.identifier,
        UTType.text.identifier
    ]

    static func provider(for appName: String) -> NSItemProvider {
        NSItemProvider(object: appName as NSString)
    }

    static func loadAppName(from providers: [NSItemProvider], perform: @escaping (String) -> Void) -> Bool {
        guard let provider = providers.first(where: { itemProvider in
            dropTypeIdentifiers.contains { itemProvider.hasItemConformingToTypeIdentifier($0) }
        }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let stringObject = item as? NSString else { return }
            let appName = String(stringObject).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appName.isEmpty else { return }
            DispatchQueue.main.async {
                perform(appName)
            }
        }
        return true
    }
}

private struct InfoBubbleButton: View {
    let text: String
    @State private var isPopoverPresented = false
    @State private var isPinnedOpen = false
    @State private var isHoveringTrigger = false
    @State private var isHoveringPopover = false
    @State private var pendingCloseWorkItem: DispatchWorkItem?

    var body: some View {
        Button {
            if isPinnedOpen {
                dismissPopover()
            } else {
                isPinnedOpen = true
                presentPopover()
            }
        } label: {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isPopoverPresented ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHoveringTrigger = hovering
            if hovering {
                presentPopover()
            } else if !isPinnedOpen {
                schedulePopoverClose()
            }
        }
        .popover(
            isPresented: Binding(
                get: { isPopoverPresented },
                set: { presented in
                    if presented {
                        presentPopover()
                    } else {
                        dismissPopover()
                    }
                }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
            .onHover { hovering in
                isHoveringPopover = hovering
                if hovering {
                    cancelScheduledClose()
                } else if !isPinnedOpen && !isHoveringTrigger {
                    schedulePopoverClose()
                }
            }
        }
        .onDisappear {
            cancelScheduledClose()
        }
    }

    private func presentPopover() {
        cancelScheduledClose()
        isPopoverPresented = true
    }

    private func dismissPopover() {
        cancelScheduledClose()
        isPinnedOpen = false
        isHoveringTrigger = false
        isHoveringPopover = false
        isPopoverPresented = false
    }

    private func schedulePopoverClose() {
        cancelScheduledClose()
        let workItem = DispatchWorkItem {
            if !isPinnedOpen && !isHoveringTrigger && !isHoveringPopover {
                isPopoverPresented = false
            }
        }
        pendingCloseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func cancelScheduledClose() {
        pendingCloseWorkItem?.cancel()
        pendingCloseWorkItem = nil
    }
}
