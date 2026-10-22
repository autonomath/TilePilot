import SwiftUI

struct WorkAreaDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedDisplayKey: String?
    @State private var lockAspectRatio = false
    @State private var newExcludedApp = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let display = selectedDisplay {
                        editorCard(display: display)
                        systemBarCard(display: display)
                        behaviorCard(display: display)
                        exceptionsCard(display: display)
                    } else {
                        unavailableCard
                    }
                }
                .padding()
            }
            .navigationTitle("TilePilot")
        }
    }

    // MARK: - Display selection

    private var displays: [DisplayState] {
        (model.liveStateSnapshot?.displays ?? [])
            .filter { $0.frameW > 1 && $0.frameH > 1 && $0.source != .fallback }
    }

    private func displayKey(_ display: DisplayState) -> String {
        display.uuid ?? "display-\(display.id)"
    }

    private var selectedDisplay: DisplayState? {
        let all = displays
        if let selectedDisplayKey, let match = all.first(where: { displayKey($0) == selectedDisplayKey }) {
            return match
        }
        // Default to the largest display, the one most likely to need a smaller area.
        return all.max { ($0.frameW * $0.frameH) < ($1.frameW * $1.frameH) }
    }

    private var unavailableCard: some View {
        GroupBox {
            Text("Display layout is unavailable right now. Start yabai, then come back to set up a Work Area.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Work Area", systemImage: "rectangle.inset.filled")
        }
    }

    // MARK: - Editor

    private func editorCard(display: DisplayState) -> some View {
        let configuration = model.workAreaConfiguration(for: display)
        let rect = model.workAreaEditorNormalizedRect(for: display)
        let displaySize = CGSize(width: display.frameW, height: display.frameH)

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if displays.count > 1 {
                        Picker("Display", selection: Binding(
                            get: { displayKey(display) },
                            set: { selectedDisplayKey = $0 }
                        )) {
                            ForEach(displays, id: \.id) { item in
                                Text(verbatim: "\(item.name) · \(Int(item.frameW)) × \(Int(item.frameH))").tag(displayKey(item))
                            }
                        }
                        .frame(maxWidth: 360)
                    } else {
                        Text(verbatim: "\(display.name) · \(Int(display.frameW)) × \(Int(display.frameH)) pt")
                            .font(.subheadline.weight(.semibold))
                    }
                    Spacer(minLength: 0)
                    Toggle("Use a Work Area on this display", isOn: Binding(
                        get: { configuration?.enabled ?? false },
                        set: { model.setWorkAreaEnabled($0, for: display) }
                    ))
                    .toggleStyle(.switch)
                }

                Text("Drag the area to move it, drag its edges to resize it, or drag outside it to draw a new one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                WorkAreaCanvas(
                    displaySize: displaySize,
                    normalizedRect: rect,
                    reservedRects: reservedRects(for: display),
                    windowRects: windowRects(for: display),
                    systemBarRect: systemBarPreviewRect(for: display),
                    isEnabled: configuration?.enabled ?? false,
                    lockAspectRatio: lockAspectRatio,
                    onChange: { model.setWorkAreaNormalizedRect($0, for: display, debounce: true) },
                    onCommit: { model.setWorkAreaNormalizedRect($0, for: display, debounce: false) }
                )
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 420)

                HStack(alignment: .bottom, spacing: 12) {
                    pointField("Width", value: pointBinding(display: display, rect: rect, dimension: .width))
                    pointField("Height", value: pointBinding(display: display, rect: rect, dimension: .height))
                    pointField("From left", value: pointBinding(display: display, rect: rect, dimension: .x))
                    pointField("From top", value: pointBinding(display: display, rect: rect, dimension: .y))
                    Spacer(minLength: 0)
                    Toggle("Lock aspect ratio", isOn: $lockAspectRatio)
                }

                HStack(spacing: 8) {
                    Text("Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(WorkAreaSizePreset.allCases) { preset in
                        Button(preset.title) { applySizePreset(preset, display: display, rect: rect) }
                    }
                    Divider().frame(height: 16)
                    Text("Position")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(WorkAreaPositionPreset.allCases) { preset in
                        Button(preset.title) { applyPositionPreset(preset, display: display, rect: rect) }
                    }
                }
                .controlSize(.small)

                statusLine(display: display, configuration: configuration)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Work Area", systemImage: "rectangle.inset.filled")
        }
    }

    private func statusLine(display: DisplayState, configuration: WorkAreaConfiguration?) -> some View {
        let text: String
        if configuration?.enabled == true, let effective = model.resolvedWorkArea(for: display) {
            let fromLeft = Int((effective.minX - display.frameX).rounded())
            let fromTop = Int((effective.minY - display.frameY).rounded())
            var line = "In use: \(Int(effective.width)) × \(Int(effective.height)) pt for windows, \(fromLeft) pt from the left and \(fromTop) pt from the top. Screen Edge Padding (\(model.windowBehaviorPolicyDraft.outerPadding) pt) still applies inside it."
            if let layout = model.resolvedSystemBarLayout(for: display) {
                line += layout.isAboveWorkArea
                    ? " The menu bar sits directly above the area."
                    : " The menu bar takes the top \(Int(layout.bar.height)) pt of the area."
            }
            text = line
        } else {
            text = "Off. Windows on this display can use the whole screen."
        }
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private enum PointDimension {
        case width, height, x, y
    }

    private func pointBinding(display: DisplayState, rect: CGRect, dimension: PointDimension) -> Binding<Int> {
        Binding(
            get: {
                switch dimension {
                case .width: return Int((rect.width * display.frameW).rounded())
                case .height: return Int((rect.height * display.frameH).rounded())
                case .x: return Int((rect.minX * display.frameW).rounded())
                case .y: return Int((rect.minY * display.frameH).rounded())
                }
            },
            set: { value in
                var updated = rect
                let points = Double(value)
                switch dimension {
                case .width: updated.size.width = points / display.frameW
                case .height: updated.size.height = points / display.frameH
                case .x: updated.origin.x = points / display.frameW
                case .y: updated.origin.y = points / display.frameH
                }
                if dimension == .width || dimension == .height {
                    // Keep the area on screen when it grows past the edge.
                    updated.origin.x = min(updated.minX, max(0, 1 - updated.width))
                    updated.origin.y = min(updated.minY, max(0, 1 - updated.height))
                }
                model.setWorkAreaNormalizedRect(updated, for: display, debounce: false)
            }
        )
    }

    private func pointField(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
        }
    }

    private func applySizePreset(_ preset: WorkAreaSizePreset, display: DisplayState, rect: CGRect) {
        let displaySize = CGSize(width: display.frameW, height: display.frameH)
        let size = preset.size(for: displaySize)
        let width = size.width / displaySize.width
        let height = size.height / displaySize.height
        let updated = CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
        model.setWorkAreaNormalizedRect(updated, for: display, debounce: false)
    }

    private func applyPositionPreset(_ preset: WorkAreaPositionPreset, display: DisplayState, rect: CGRect) {
        let updated = WorkAreaGeometry.normalizedRect(
            size: CGSize(width: rect.width * display.frameW, height: rect.height * display.frameH),
            position: preset,
            displaySize: CGSize(width: display.frameW, height: display.frameH)
        )
        model.setWorkAreaNormalizedRect(updated, for: display, debounce: false)
    }

    private func reservedRects(for display: DisplayState) -> [CGRect] {
        guard let visible = model.workAreaVisibleFrame(for: display) else { return [] }
        let displayFrame = model.workAreaDisplayFrame(for: display)
        let usable = WorkAreaGeometry.normalizedRect(absolute: visible.intersection(displayFrame), displayFrame: displayFrame)
        var rects: [CGRect] = []
        if usable.minY > 0.001 { rects.append(CGRect(x: 0, y: 0, width: 1, height: usable.minY)) }
        if usable.maxY < 0.999 { rects.append(CGRect(x: 0, y: usable.maxY, width: 1, height: 1 - usable.maxY)) }
        if usable.minX > 0.001 { rects.append(CGRect(x: 0, y: usable.minY, width: usable.minX, height: usable.height)) }
        if usable.maxX < 0.999 { rects.append(CGRect(x: usable.maxX, y: usable.minY, width: 1 - usable.maxX, height: usable.height)) }
        return rects
    }

    /// The System Bar strip as a fraction of the display, for the canvas preview.
    private func systemBarPreviewRect(for display: DisplayState) -> CGRect? {
        guard let layout = model.resolvedSystemBarLayout(for: display) else { return nil }
        return WorkAreaGeometry.normalizedRect(absolute: layout.bar, displayFrame: model.workAreaDisplayFrame(for: display))
    }

    private func windowRects(for display: DisplayState) -> [CGRect] {
        guard let snapshot = model.liveStateSnapshot else { return [] }
        let visibleSpaces = Set(snapshot.spaces.filter(\.visible).map(\.index))
        let displayFrame = model.workAreaDisplayFrame(for: display)
        return snapshot.windows
            .filter { $0.display == display.id && visibleSpaces.contains($0.space) && $0.isVisible && !$0.isMinimized && !$0.isHidden }
            .map {
                WorkAreaGeometry.normalizedRect(
                    absolute: CGRect(x: $0.frameX, y: $0.frameY, width: $0.frameW, height: $0.frameH),
                    displayFrame: displayFrame
                )
            }
    }

    // MARK: - Behavior

    private func behaviorCard(display: DisplayState) -> some View {
        let configuration = model.workAreaConfiguration(for: display)
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Keep windows inside", isOn: Binding(
                    get: { configuration?.containmentEnabled ?? true },
                    set: { model.setWorkAreaContainmentEnabled($0, for: display) }
                ))
                .toggleStyle(.switch)
                .disabled(configuration?.enabled != true)

                Text("Tiled windows always stay inside the area. With this on, floating windows that end up outside move back in after you let go of the mouse. Double-click a title bar to make a window fill the area.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The Dock and notifications keep using the whole display. The real menu bar stays at the top of the screen even when it is mirrored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Undo Last Fit") { model.undoLastWorkAreaFit() }
                        .disabled(!model.canUndoLastWorkAreaFit)
                    Text("Puts the windows TilePilot just moved back where they were and lets them stay outside.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Keeping Windows Inside", systemImage: "arrow.down.right.and.arrow.up.left")
        }
    }

    // MARK: - Menu bar

    private func systemBarCard(display: DisplayState) -> some View {
        let configuration = model.workAreaConfiguration(for: display)
        let workAreaOn = configuration?.enabled == true
        let barOn = configuration?.systemBarEnabled == true
        let screenRecordingOn = model.megamapScreenRecordingAuthorized
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show the menu bar at the top of the Work Area", isOn: Binding(
                    get: { barOn },
                    set: { model.setSystemBarEnabled($0, for: display) }
                ))
                .toggleStyle(.switch)
                .disabled(!workAreaOn)

                Text("Shows the app menus and this display's menu bar icons. Menus open right under it and the frontmost app stays frontmost; icon panels open at the real menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Also show icons from other displays", isOn: Binding(
                    get: { model.systemBarOtherDisplayIconsEnabled },
                    set: { model.setSystemBarOtherDisplayIconsEnabled($0) }
                ))
                .toggleStyle(.switch)
                .disabled(!workAreaOn || !barOn)

                Text("macOS draws most third-party icons only on the main display's menu bar. With this on, those icons appear here too; clicking one opens its menu here, but panels open on the other display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Match the real icons", isOn: Binding(
                    get: { model.systemBarMatchingIconsEnabled },
                    set: { model.setSystemBarMatchingIconsEnabled($0) }
                ))
                .toggleStyle(.switch)
                .disabled(!workAreaOn || !barOn)

                HStack(spacing: 8) {
                    Text("Menu bar icons: \(model.systemBarIconModeDescription).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.systemBarMatchingIconsEnabled, !screenRecordingOn {
                        Button("Allow Screen Recording…") { model.requestScreenRecordingAccessPrompt() }
                            .controlSize(.small)
                    }
                }
                Text(model.systemBarMatchingIconsEnabled
                    ? "Matching copies each icon's pixels from the real menu bar and needs Screen Recording. Simplified draws symbols and app icons instead."
                    : "Simplified draws symbols, text, and app icons; nothing is captured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Menu Bar", systemImage: "menubar.rectangle")
        }
    }

    // MARK: - Exceptions

    private func exceptionsCard(display: DisplayState) -> some View {
        let configuration = model.workAreaConfiguration(for: display)
        let excludedApps = configuration?.excludedApps ?? []
        let unfitWindows = model.workAreaUnfitWindows.filter { $0.displayID == display.id }
        let openApps = model.availableAppNamesFromLiveState.filter { app in
            !(configuration?.excludesApp(app) ?? false)
        }

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Apps Allowed Outside").font(.headline)
                    Text("Windows from these apps can sit anywhere on this display.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("App name (e.g. Finder)", text: $newExcludedApp)
                            .onSubmit(addExcludedApp(display: display))
                        Button("Add", action: addExcludedApp(display: display))
                            .disabled(newExcludedApp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !openApps.isEmpty {
                            Menu("Add Open App") {
                                ForEach(openApps, id: \.self) { app in
                                    Button(app) { model.addWorkAreaExcludedApp(app, for: display) }
                                }
                            }
                            .fixedSize()
                        }
                    }
                    if excludedApps.isEmpty {
                        Text("No apps configured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(excludedApps, id: \.self) { app in
                            HStack(spacing: 8) {
                                AppNameWithIconView(appName: app)
                                Button("Remove") { model.removeWorkAreaExcludedApp(app, for: display) }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }

                if !unfitWindows.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Windows That Couldn't Fit").font(.headline)
                        Text("These windows refused to move or shrink inside the area. TilePilot tries again every 30 seconds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(unfitWindows) { window in
                            HStack(spacing: 8) {
                                AppNameWithIconView(appName: window.app)
                                if !window.title.isEmpty {
                                    Text(window.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Button("Allow Outside") { model.allowWorkAreaWindowOutside(windowID: window.windowID) }
                                    .font(.caption)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Exceptions", systemImage: "rectangle.portrait.and.arrow.right")
        }
    }

    private func addExcludedApp(display: DisplayState) -> () -> Void {
        {
            model.addWorkAreaExcludedApp(newExcludedApp, for: display)
            newExcludedApp = ""
        }
    }
}

// MARK: - Canvas

private enum WorkAreaHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

    func point(in rect: CGRect) -> CGPoint {
        let x = movesLeft ? rect.minX : (movesRight ? rect.maxX : rect.midX)
        let y = movesTop ? rect.minY : (movesBottom ? rect.maxY : rect.midY)
        return CGPoint(x: x, y: y)
    }
}

private enum WorkAreaDragMode {
    case move
    case resize(WorkAreaHandle)
    case draw(anchor: CGPoint)
}

private struct WorkAreaCanvas: View {
    let displaySize: CGSize
    let normalizedRect: CGRect
    let reservedRects: [CGRect]
    let windowRects: [CGRect]
    let systemBarRect: CGRect?
    let isEnabled: Bool
    let lockAspectRatio: Bool
    let onChange: (CGRect) -> Void
    let onCommit: (CGRect) -> Void

    @State private var dragMode: WorkAreaDragMode?
    @State private var dragOriginRect: CGRect = .zero
    @State private var liveRect: CGRect?

    private var minimumNormalizedSize: CGSize {
        CGSize(
            width: min(1, WorkAreaConfiguration.minimumSize.width / max(displaySize.width, 1)),
            height: min(1, WorkAreaConfiguration.minimumSize.height / max(displaySize.height, 1))
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let rect = liveRect ?? normalizedRect
            let canvasRect = scaled(rect, to: size)
            let accent = isEnabled ? Color.accentColor : Color.secondary

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))

                ForEach(Array(reservedRects.enumerated()), id: \.offset) { _, reserved in
                    let frame = scaled(reserved, to: size)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }

                ForEach(Array(windowRects.enumerated()), id: \.offset) { _, window in
                    let frame = scaled(window, to: size)
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.secondary.opacity(0.45), lineWidth: 1)
                        .frame(width: max(frame.width, 2), height: max(frame.height, 2))
                        .position(x: frame.midX, y: frame.midY)
                }

                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(canvasRect)
                }
                .fill(Color.black.opacity(isEnabled ? 0.22 : 0.08), style: FillStyle(eoFill: true))

                Rectangle()
                    .fill(accent.opacity(0.10))
                    .overlay(Rectangle().stroke(accent, lineWidth: 2))
                    .frame(width: canvasRect.width, height: canvasRect.height)
                    .position(x: canvasRect.midX, y: canvasRect.midY)

                if let systemBarRect, liveRect == nil {
                    let barFrame = scaled(systemBarRect, to: size)
                    Rectangle()
                        .fill(accent.opacity(0.55))
                        .frame(width: barFrame.width, height: max(barFrame.height, 3))
                        .position(x: barFrame.midX, y: barFrame.midY)
                }

                Text(verbatim: "\(Int((rect.width * displaySize.width).rounded())) × \(Int((rect.height * displaySize.height).rounded()))")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .position(x: canvasRect.midX, y: canvasRect.midY)

                ForEach(WorkAreaHandle.allCases, id: \.self) { handle in
                    let point = handle.point(in: canvasRect)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(accent, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .position(point)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .local)
                    .onChanged { value in handleDragChanged(value, canvasSize: size) }
                    .onEnded { _ in handleDragEnded() }
            )
        }
        .aspectRatio(displaySize.width / max(displaySize.height, 1), contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Work Area preview")
        .accessibilityValue("\(Int((normalizedRect.width * displaySize.width).rounded())) by \(Int((normalizedRect.height * displaySize.height).rounded())) points")
    }

    private func scaled(_ rect: CGRect, to size: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * size.width,
            y: rect.minY * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )
    }

    private func handleDragChanged(_ value: DragGesture.Value, canvasSize: CGSize) {
        guard canvasSize.width > 1, canvasSize.height > 1 else { return }
        if dragMode == nil {
            dragOriginRect = normalizedRect
            dragMode = mode(at: value.startLocation, canvasSize: canvasSize)
        }
        guard let dragMode else { return }

        let dx = value.translation.width / canvasSize.width
        let dy = value.translation.height / canvasSize.height
        let updated: CGRect
        switch dragMode {
        case .move:
            updated = CGRect(
                x: min(max(0, dragOriginRect.minX + dx), 1 - dragOriginRect.width),
                y: min(max(0, dragOriginRect.minY + dy), 1 - dragOriginRect.height),
                width: dragOriginRect.width,
                height: dragOriginRect.height
            )
        case .resize(let handle):
            updated = resized(dragOriginRect, handle: handle, dx: dx, dy: dy)
        case .draw(let anchor):
            let current = CGPoint(
                x: min(max(0, value.location.x / canvasSize.width), 1),
                y: min(max(0, value.location.y / canvasSize.height), 1)
            )
            updated = CGRect(
                x: min(anchor.x, current.x),
                y: min(anchor.y, current.y),
                width: abs(current.x - anchor.x),
                height: abs(current.y - anchor.y)
            )
        }
        liveRect = updated
        if case .draw = dragMode { return }
        onChange(updated)
    }

    private func handleDragEnded() {
        if let liveRect {
            onCommit(liveRect)
        }
        liveRect = nil
        dragMode = nil
    }

    private func mode(at location: CGPoint, canvasSize: CGSize) -> WorkAreaDragMode {
        let canvasRect = scaled(normalizedRect, to: canvasSize)
        let hitRadius: CGFloat = 10
        if let handle = WorkAreaHandle.allCases.first(where: { handle in
            let point = handle.point(in: canvasRect)
            return hypot(point.x - location.x, point.y - location.y) <= hitRadius
        }) {
            return .resize(handle)
        }
        if canvasRect.insetBy(dx: -hitRadius / 2, dy: -hitRadius / 2).contains(location) {
            // Near an edge but between handles still resizes that edge.
            let edgeBand = hitRadius / 2
            if abs(location.x - canvasRect.minX) <= edgeBand { return .resize(.left) }
            if abs(location.x - canvasRect.maxX) <= edgeBand { return .resize(.right) }
            if abs(location.y - canvasRect.minY) <= edgeBand { return .resize(.top) }
            if abs(location.y - canvasRect.maxY) <= edgeBand { return .resize(.bottom) }
            return .move
        }
        return .draw(anchor: CGPoint(
            x: min(max(0, location.x / canvasSize.width), 1),
            y: min(max(0, location.y / canvasSize.height), 1)
        ))
    }

    private func resized(_ origin: CGRect, handle: WorkAreaHandle, dx: CGFloat, dy: CGFloat) -> CGRect {
        let minSize = minimumNormalizedSize
        var minX = origin.minX
        var maxX = origin.maxX
        var minY = origin.minY
        var maxY = origin.maxY
        if handle.movesLeft { minX = min(max(0, origin.minX + dx), maxX - minSize.width) }
        if handle.movesRight { maxX = max(min(1, origin.maxX + dx), minX + minSize.width) }
        if handle.movesTop { minY = min(max(0, origin.minY + dy), maxY - minSize.height) }
        if handle.movesBottom { maxY = max(min(1, origin.maxY + dy), minY + minSize.height) }

        guard lockAspectRatio, origin.height > 0, displaySize.height > 0 else {
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        // Aspect ratio in points, so the lock matches what the user sees on the real display.
        let aspect = (origin.width * displaySize.width) / (origin.height * displaySize.height)
        let heightForWidth: (CGFloat) -> CGFloat = { width in width * displaySize.width / aspect / displaySize.height }
        let widthForHeight: (CGFloat) -> CGFloat = { height in height * displaySize.height * aspect / displaySize.width }

        if handle.isCorner || handle.movesLeft || handle.movesRight {
            var width = maxX - minX
            var height = heightForWidth(width)
            if height > 1 {
                height = 1
                width = widthForHeight(height)
            }
            if handle.isCorner {
                if handle.movesLeft { minX = maxX - width } else { maxX = minX + width }
                if handle.movesTop { minY = maxY - height } else { maxY = minY + height }
            } else {
                let centerY = origin.midY
                minY = centerY - height / 2
                maxY = centerY + height / 2
            }
        } else {
            var height = maxY - minY
            var width = widthForHeight(height)
            if width > 1 {
                width = 1
                height = heightForWidth(width)
                if handle.movesTop { minY = maxY - height } else { maxY = minY + height }
            }
            let centerX = origin.midX
            minX = centerX - width / 2
            maxX = centerX + width / 2
        }

        var rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        rect.origin.x = min(max(0, rect.minX), max(0, 1 - rect.width))
        rect.origin.y = min(max(0, rect.minY), max(0, 1 - rect.height))
        return rect
    }
}
