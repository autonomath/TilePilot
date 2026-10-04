import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RecentWindowTilerPickerView: View {
    @ObservedObject var model: AppModel

    private let rowHeight: CGFloat = 36
    private let monitorDividerHeight: CGFloat = 24
    @State private var draggedWindowID: Int?

    var body: some View {
        Group {
            if let state = model.recentWindowTilerState {
                VStack(alignment: .leading, spacing: 10) {
                    header(state: state)

                    modePickerRow(state: state)

                    RecentWindowTilerResultPreview(
                        state: state,
                        displayAspectRatio: state.displayAspectRatio,
                        draggedWindowID: $draggedWindowID,
                        model: model
                    )

                    let idealListHeight = listHeight(for: state)
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(state.candidates.enumerated()), id: \.element.windowID) { index, candidate in
                                VStack(spacing: 4) {
                                    if shouldShowOtherMonitorDivider(index: index, candidates: state.candidates) {
                                        RecentWindowTilerMonitorDivider()
                                    }

                                    RecentWindowTilerCandidateRow(
                                        order: index + 1,
                                        candidate: candidate,
                                        mode: state.mode,
                                        isSelected: state.effectiveSelectedWindowIDs.contains(candidate.windowID),
                                        isEnabled: candidate.isSelectable(in: state.mode),
                                        onFocus: {
                                            model.focusRecentWindowTilerCandidate(windowID: candidate.windowID)
                                        },
                                        onClose: {
                                            model.closeRecentWindowTilerCandidate(windowID: candidate.windowID)
                                        }
                                    ) {
                                        model.toggleRecentWindowTilerSelection(windowID: candidate.windowID)
                                    }
                                    .onDrag {
                                        draggedWindowID = candidate.windowID
                                        return NSItemProvider(object: "\(candidate.windowID)" as NSString)
                                    }
                                    .onDrop(
                                        of: [UTType.utf8PlainText.identifier, UTType.plainText.identifier],
                                        delegate: RecentWindowTilerCandidateDropDelegate(
                                            targetWindowID: candidate.windowID,
                                            draggedWindowID: $draggedWindowID,
                                            model: model
                                        )
                                    )
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .frame(minHeight: min(idealListHeight, rowHeight), idealHeight: idealListHeight, maxHeight: .infinity)

                    HStack {
                        Text("\(state.selectedCount) selected")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(state.selectedCount == 0 ? .red : .secondary)

                        Spacer()

                        Button("Cancel") {
                            model.dismissRecentWindowTiler()
                        }
                        .keyboardShortcut(.cancelAction)

                        Button(primaryActionTitle(for: state)) {
                            model.applyRecentWindowTilerSelection()
                        }
                        .buttonStyle(RecentWindowTilerPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canApply(state))
                    }
                }
                .padding(16)
                .frame(minWidth: 500, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
            } else {
                EmptyView()
                    .frame(minWidth: 500, minHeight: 120)
            }
        }
    }

    @ViewBuilder
    private func modePickerRow(state: RecentWindowTilerPresentationState) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { state.mode },
                set: { model.setRecentWindowTilerMode($0) }
            )) {
                ForEach(RecentWindowTilerMode.pickerModes) { mode in
                    Text(mode.displayName).tag(mode)
                        .disabled(mode == .template && !state.canUseTemplateMode)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 220, maxWidth: 300)

            if state.mode == .template {
                templatePicker(state: state)
                    .frame(minWidth: 180, maxWidth: .infinity)
            }

            Toggle("Backdrop", isOn: Binding(
                get: { state.backdropEnabled },
                set: { model.setRecentWindowTilerBackdropEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .fixedSize()

            ColorPicker(
                "",
                selection: Binding(
                    get: { state.backdropColor.swiftUIColor },
                    set: { newColor in
                        guard let color = OverlayAccentColor.from(swiftUIColor: newColor) else { return }
                        model.setRecentWindowTilerBackdropColor(color)
                    }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 32)
            .help("Backdrop color")
        }
    }

    @ViewBuilder
    private func templatePicker(state: RecentWindowTilerPresentationState) -> some View {
        if state.templateOptions.isEmpty {
            Text("No matching templates for this display.")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        } else {
            Picker("", selection: Binding(
                get: { state.selectedTemplateID },
                set: { if let templateID = $0 { model.setRecentWindowTilerTemplate(templateID) } }
            )) {
                ForEach(state.templateOptions) { template in
                    Text("\(template.name) · \(template.slotCount) slot\(template.slotCount == 1 ? "" : "s")")
                        .tag(Optional(template.id))
                }
            }
            .labelsHidden()
        }
    }

    private func primaryActionTitle(for state: RecentWindowTilerPresentationState) -> String {
        switch state.mode {
        case .autoTiled:
            return "Tile Selected Windows"
        case .floatingGrid:
            return "Arrange Selected Windows"
        case .template:
            return "Apply Template"
        }
    }

    private func canApply(_ state: RecentWindowTilerPresentationState) -> Bool {
        guard state.selectedCount > 0 else { return false }
        guard state.mode != .template || state.selectedTemplateID != nil else { return false }
        return true
    }

    private func header(state: RecentWindowTilerPresentationState) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Pick Windows to Tile")
                .font(.title3.weight(.semibold))
            Text("Drag to reorder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            if state.targetOptions.count > 1 {
                Menu {
                    ForEach(state.targetOptions) { target in
                        Button {
                            model.setRecentWindowTilerTargetDisplay(target.displayID)
                        } label: {
                            if target.displayID == currentTargetOption(state: state)?.displayID {
                                Label(target.title, systemImage: "checkmark")
                            } else {
                                Text(target.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "display")
                        Text(compactTargetTitle(state: state))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .frame(maxWidth: 180)
                .help("Choose which monitor this picker will arrange windows on")
            }

            Button {
                model.refreshRecentWindowTiler()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .help("Refresh this picker snapshot")
        }
    }

    private func currentTargetOption(state: RecentWindowTilerPresentationState) -> RecentWindowTilerTargetOption? {
        let targetDisplayID = state.targetDisplayID ?? state.targetOptions.first?.displayID
        return state.targetOptions.first(where: { $0.displayID == targetDisplayID }) ?? state.targetOptions.first
    }

    private func compactTargetTitle(state: RecentWindowTilerPresentationState) -> String {
        guard let target = currentTargetOption(state: state) else { return "Display" }
        return "\(target.displayName) · D\(target.spaceIndex)"
    }

    private func listHeight(for state: RecentWindowTilerPresentationState) -> CGFloat {
        let count = state.candidates.count
        let visibleCount = min(max(count, 1), 10)
        let dividerHeight = hasOtherMonitorDivider(state.candidates) ? monitorDividerHeight + 6 : 0
        return CGFloat(visibleCount) * rowHeight + CGFloat(max(0, visibleCount - 1) * 4) + dividerHeight
    }

    private func hasOtherMonitorDivider(_ candidates: [RecentWindowTilerCandidate]) -> Bool {
        candidates.contains { !$0.isOnTargetDisplay }
    }

    private func shouldShowOtherMonitorDivider(index: Int, candidates: [RecentWindowTilerCandidate]) -> Bool {
        guard candidates.indices.contains(index),
              !candidates[index].isOnTargetDisplay else {
            return false
        }
        return index == 0 || candidates[index - 1].isOnTargetDisplay
    }
}

private struct RecentWindowTilerMonitorDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)

            Label("Other monitor", systemImage: "display.2")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
        }
        .frame(height: 24)
        .padding(.horizontal, 4)
        .accessibilityLabel("Windows from another monitor")
    }
}

private struct RecentWindowTilerResultPreview: View {
    let state: RecentWindowTilerPresentationState
    let displayAspectRatio: Double
    @Binding var draggedWindowID: Int?
    let model: AppModel

    var body: some View {
        if state.mode == .template, let template = state.selectedTemplateOption {
            RecentWindowTilerTemplatePreview(
                template: template,
                slotCandidates: state.templateSlotCandidates,
                displayAspectRatio: displayAspectRatio,
                draggedWindowID: $draggedWindowID,
                model: model
            )
        } else {
            RecentWindowTilerGridPreview(
                candidates: state.orderedEffectiveSelectedCandidates,
                displayAspectRatio: displayAspectRatio,
                draggedWindowID: $draggedWindowID,
                model: model
            )
        }
    }
}

private struct RecentWindowTilerGridPreview: View {
    let candidates: [RecentWindowTilerCandidate]
    let displayAspectRatio: Double
    @Binding var draggedWindowID: Int?
    let model: AppModel

    private var grid: (rows: Int, cols: Int) {
        RecentWindowGridPlanner.dimensions(
            windowCount: candidates.count,
            displayAspectRatio: displayAspectRatio
        )
    }

    private var placements: [RecentWindowGridPlacement] {
        RecentWindowGridPlanner.placements(
            windowCount: candidates.count,
            rows: grid.rows,
            cols: grid.cols
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { proxy in
                let canvas = previewCanvasSize(in: proxy.size)
                let origin = CGPoint(
                    x: (proxy.size.width - canvas.width) / 2,
                    y: (proxy.size.height - canvas.height) / 2
                )

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.06))
                        .frame(width: canvas.width, height: canvas.height)
                        .position(x: origin.x + (canvas.width / 2), y: origin.y + (canvas.height / 2))

                    ForEach(0..<(grid.rows * grid.cols), id: \.self) { index in
                        let row = index / max(grid.cols, 1)
                        let col = index % max(grid.cols, 1)
                        let rect = cellRect(row: row, col: col, rowSpan: 1, colSpan: 1, canvas: canvas)

                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: origin.x + rect.midX, y: origin.y + rect.midY)
                    }

                    ForEach(Array(candidates.enumerated()), id: \.element.windowID) { index, candidate in
                        if placements.indices.contains(index) {
                            let placement = placements[index]
                            let rect = cellRect(
                                row: placement.row,
                                col: placement.col,
                                rowSpan: placement.rowSpan,
                                colSpan: placement.colSpan,
                                canvas: canvas
                            )
                            let iconSize = min(44, max(30, min(rect.width, rect.height) * 0.66))

                            RecentWindowTilerGridPreviewTile(candidate: candidate, order: index + 1, iconSize: iconSize)
                                .frame(width: rect.width, height: rect.height)
                                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .position(x: origin.x + rect.midX, y: origin.y + rect.midY)
                                .zIndex(Double(index + 1))
                                .gesture(
                                    DragGesture(minimumDistance: 3, coordinateSpace: .named("RecentWindowTilerPreview"))
                                        .onChanged { value in
                                            let activeWindowID = draggedWindowID ?? candidate.windowID
                                            draggedWindowID = activeWindowID

                                            guard let targetWindowID = previewTargetWindowID(
                                                at: value.location,
                                                canvas: canvas,
                                                origin: origin
                                            ),
                                                targetWindowID != activeWindowID else {
                                                return
                                            }

                                            model.reorderRecentWindowTilerCandidate(
                                                draggedWindowID: activeWindowID,
                                                targetWindowID: targetWindowID
                                            )
                                        }
                                        .onEnded { _ in
                                            draggedWindowID = nil
                                        }
                                )
                        }
                    }
                }
                .coordinateSpace(name: "RecentWindowTilerPreview")
            }
            .frame(height: 146)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func previewCanvasSize(in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let aspectRatio = max(displayAspectRatio, 0.5)
        let widthFromHeight = size.height * aspectRatio
        if widthFromHeight <= size.width {
            return CGSize(width: widthFromHeight, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / aspectRatio)
    }

    private func cellRect(
        row: Int,
        col: Int,
        rowSpan: Int,
        colSpan: Int,
        canvas: CGSize
    ) -> CGRect {
        let gap: CGFloat = 5
        let cols = CGFloat(max(grid.cols, 1))
        let rows = CGFloat(max(grid.rows, 1))
        let cellWidth = (canvas.width - ((cols - 1) * gap)) / cols
        let cellHeight = (canvas.height - ((rows - 1) * gap)) / rows
        return CGRect(
            x: CGFloat(col) * (cellWidth + gap),
            y: CGFloat(row) * (cellHeight + gap),
            width: (cellWidth * CGFloat(max(colSpan, 1))) + (gap * CGFloat(max(colSpan - 1, 0))),
            height: (cellHeight * CGFloat(max(rowSpan, 1))) + (gap * CGFloat(max(rowSpan - 1, 0)))
        )
    }

    private func previewTargetWindowID(at point: CGPoint, canvas: CGSize, origin: CGPoint) -> Int? {
        for (index, candidate) in candidates.enumerated().reversed() {
            guard placements.indices.contains(index) else { continue }
            let placement = placements[index]
            let rect = cellRect(
                row: placement.row,
                col: placement.col,
                rowSpan: placement.rowSpan,
                colSpan: placement.colSpan,
                canvas: canvas
            ).offsetBy(dx: origin.x, dy: origin.y)
            if rect.contains(point) {
                return candidate.windowID
            }
        }
        return nil
    }
}

private struct RecentWindowTilerTemplatePreview: View {
    let template: RecentWindowTilerTemplateOption
    let slotCandidates: [RecentWindowTilerCandidate?]
    let displayAspectRatio: Double
    @Binding var draggedWindowID: Int?
    let model: AppModel

    private var slots: [WindowLayoutSlot] {
        WindowLayoutTemplate.sortedSlots(template.slots)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { proxy in
                let canvas = previewCanvasSize(in: proxy.size)
                let origin = CGPoint(
                    x: (proxy.size.width - canvas.width) / 2,
                    y: (proxy.size.height - canvas.height) / 2
                )

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.06))
                        .frame(width: canvas.width, height: canvas.height)
                        .position(x: origin.x + (canvas.width / 2), y: origin.y + (canvas.height / 2))

                    ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                        let rect = previewRect(for: slot, canvas: canvas)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.secondary.opacity(0.05))
                            )
                            .frame(width: rect.width, height: rect.height)
                            .position(x: origin.x + rect.midX, y: origin.y + rect.midY)

                        Text("\(index + 1)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(5)
                            .position(x: origin.x + rect.minX + 14, y: origin.y + rect.minY + 14)
                    }

                    ForEach(slots.indices, id: \.self) { index in
                        if slotCandidates.indices.contains(index),
                           let candidate = slotCandidates[index] {
                            let slot = slots[index]
                            let rect = previewRect(for: slot, canvas: canvas)
                            let iconSize = min(56, max(32, min(rect.width, rect.height) * 0.68))

                            RecentWindowTilerGridPreviewTile(candidate: candidate, order: index + 1, iconSize: iconSize)
                                .frame(width: rect.width, height: rect.height)
                                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .position(x: origin.x + rect.midX, y: origin.y + rect.midY)
                                .zIndex(Double(index + 1))
                                .gesture(
                                    DragGesture(minimumDistance: 3, coordinateSpace: .named("RecentWindowTilerTemplatePreview"))
                                        .onChanged { value in
                                            let activeWindowID = draggedWindowID ?? candidate.windowID
                                            draggedWindowID = activeWindowID

                                            guard let targetWindowID = previewTargetWindowID(
                                                at: value.location,
                                                canvas: canvas,
                                                origin: origin
                                            ),
                                                targetWindowID != activeWindowID else {
                                                return
                                            }

                                            model.reorderRecentWindowTilerCandidate(
                                                draggedWindowID: activeWindowID,
                                                targetWindowID: targetWindowID
                                            )
                                        }
                                        .onEnded { _ in
                                            draggedWindowID = nil
                                        }
                                )
                        }
                    }
                }
                .coordinateSpace(name: "RecentWindowTilerTemplatePreview")
            }
            .frame(height: 192)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func previewCanvasSize(in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let aspectRatio = max(displayAspectRatio, 0.5)
        let widthFromHeight = size.height * aspectRatio
        if widthFromHeight <= size.width {
            return CGSize(width: widthFromHeight, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / aspectRatio)
    }

    private func previewRect(for slot: WindowLayoutSlot, canvas: CGSize) -> CGRect {
        let fitted = RecentWindowTemplatePlanner.fittedNormalizedRect(
            for: slot,
            template: template,
            targetAspectRatio: Double(canvas.width / max(canvas.height, 1))
        )
        return CGRect(
            x: fitted.minX * canvas.width,
            y: fitted.minY * canvas.height,
            width: fitted.width * canvas.width,
            height: fitted.height * canvas.height
        )
    }

    private func previewTargetWindowID(at point: CGPoint, canvas: CGSize, origin: CGPoint) -> Int? {
        for index in slots.indices.reversed() {
            guard slotCandidates.indices.contains(index),
                  let candidate = slotCandidates[index] else { continue }
            let rect = previewRect(for: slots[index], canvas: canvas).offsetBy(dx: origin.x, dy: origin.y)
            if rect.contains(point) {
                return candidate.windowID
            }
        }
        return nil
    }
}

private struct RecentWindowTilerGridPreviewTile: View {
    let candidate: RecentWindowTilerCandidate
    let order: Int
    let iconSize: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.88))

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.blue.opacity(0.46), lineWidth: 1.25)

            if let icon = AppIconResolver.shared.icon(forAppNamed: candidate.app, size: iconSize) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .help(candidate.primaryDisplayText)
            }

            Text("\(order)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue.opacity(0.95), in: Circle())
                .padding(4)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .help(candidate.secondaryDisplayText.map { "\(candidate.primaryDisplayText) - \($0)" } ?? candidate.primaryDisplayText)
    }
}

private struct RecentWindowTilerCandidateDropDelegate: DropDelegate {
    let targetWindowID: Int
    @Binding var draggedWindowID: Int?
    let model: AppModel

    func dropEntered(info: DropInfo) {
        guard let draggedWindowID, draggedWindowID != targetWindowID else { return }
        model.reorderRecentWindowTilerCandidate(
            draggedWindowID: draggedWindowID,
            targetWindowID: targetWindowID
        )
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedWindowID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct RecentWindowTilerPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isEnabled ? Color.blue : Color.secondary.opacity(0.35))
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct RecentWindowTilerCandidateRow: View {
    let order: Int
    let candidate: RecentWindowTilerCandidate
    let mode: RecentWindowTilerMode
    let isSelected: Bool
    let isEnabled: Bool
    let onFocus: () -> Void
    let onClose: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("\(order)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 22, height: 22)
                    .background(isSelected ? Color.blue : Color.secondary.opacity(0.13), in: Circle())

                Image(nsImage: appIcon(pid: candidate.pid))
                    .resizable()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                HStack(spacing: 5) {
                    Text(candidate.primaryDisplayText)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if candidate.focused {
                        chip("Focused", tint: .blue)
                    }
                    if candidate.minimized {
                        chip("Minimized", tint: .secondary)
                    }
                    if candidate.isAXOnly {
                        chip("AX-only", tint: .teal)
                    }
                    if candidate.floating {
                        chip("Floating", tint: .orange)
                    }
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(checkColor)
            }
            .opacity(isEnabled ? 1 : 0.56)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isEnabled else { return }
                onToggle()
            }

            Button(action: onFocus) {
                Image(systemName: "eye")
                    .font(.callout.weight(.semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(RecentWindowTilerIconButtonStyle(tint: .blue))
            .help("Focus this window")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(RecentWindowTilerIconButtonStyle(tint: .red))
            .help("Close this window")
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.blue.opacity(0.32) : Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(Color.blue.opacity(0.68))
                    .frame(width: 3)
                    .padding(.vertical, 7)
                    .padding(.leading, 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(candidate.disabledReason(in: mode) ?? rowHelpText)
    }

    private var rowHelpText: String {
        candidate.secondaryDisplayText.map { "\(candidate.primaryDisplayText) - \($0)" } ?? candidate.primaryDisplayText
    }

    private var rowBackground: Color {
        isSelected ? Color.blue.opacity(0.045) : Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }

    private var checkColor: Color {
        if !isEnabled { return Color.secondary.opacity(0.35) }
        return isSelected ? Color.blue : Color.secondary.opacity(0.55)
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(tint.opacity(0.10), in: Capsule())
            .foregroundStyle(tint.opacity(0.9))
    }

    private func appIcon(pid: Int) -> NSImage {
        if let icon = NSRunningApplication(processIdentifier: pid_t(pid))?.icon {
            return icon
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "App") ?? NSImage(size: NSSize(width: 28, height: 28))
    }
}

private struct RecentWindowTilerIconButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .background(
                Circle()
                    .fill(tint.opacity(configuration.isPressed ? 0.18 : 0.07))
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
