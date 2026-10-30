import SwiftUI

struct NowDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedWindowID: Int?
    /// Width available to the mini-map, so desktop cards can grow to use it.
    @State private var miniMapWidth: CGFloat = 0

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.shouldShowAvailableUpdateBanner,
                           let release = model.availableAppUpdateRelease {
                            availableUpdateBanner(release: release)
                        }

                        if model.shouldShowWindowBehaviorRecommendation {
                            GroupBox {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Windows moving around too much?")
                                        .font(.headline)
                                    Text("Stabilize your Mac by floating new windows by default and disabling hover focus.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    HStack {
                                        Button("Float New Windows by Default") { model.enableManualTilingMode() }
                                        Button("Disable Hover Focus") { model.disableHoverFocus() }
                                        Button("Open Behaviors") {
                                            model.openWindowBehaviorSettings()
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                Label("Recommended", systemImage: "sparkles")
                            }
                        }

                        if let snapshot = model.liveStateSnapshot {
                            if shouldShowStaleOverviewNotice(for: snapshot), let reason = snapshot.degradedReason {
                                staleOverviewNotice(reason: reason)
                            }

                            if shouldShowPreciseOverview(for: snapshot) {
                                desktopPreviewCard(snapshot, scrollProxy: scrollProxy)
                                yabaiMapCard(snapshot)
                            } else if snapshot.source == .yabai {
                                if snapshot.degraded, let reason = snapshot.degradedReason {
                                    degradedBanner(reason: reason)
                                }
                                desktopPreviewUnavailableCard(snapshot)
                                fallbackMapCard(snapshot)
                            } else {
                                if snapshot.degraded, let reason = snapshot.degradedReason {
                                    degradedBanner(reason: reason)
                                }
                                desktopPreviewUnavailableCard(snapshot)
                                fallbackMapCard(snapshot)
                            }
                        } else {
                            EmptyStateView(
                                title: "Loading windows",
                                systemImage: "rectangle.3.group",
                                message: "Loading your windows and desktops. If `yabai` is unavailable, the app falls back to a simpler display view."
                            )
                        }
                    }
                    .padding()
                    .animation(model.overlayRefreshPolicy == .full ? .default : nil, value: model.overviewDisplayPreviews)
                    .animation(model.overlayRefreshPolicy == .full ? .default : nil, value: model.overviewDisplaySections)
                    .animation(model.overlayRefreshPolicy == .full ? .default : nil, value: model.liveStateSnapshot)
                }
                .navigationTitle("TilePilot")
                .task {
                    await model.refreshLiveState()
                    model.ensureOverviewCachesIfNeeded()
                }
                .onAppear {
                    model.ensureOverviewCachesIfNeeded()
                }
            }
        }
    }

    private func availableUpdateBanner(release: AppUpdateReleaseInfo) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.down.app.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("TilePilot \(release.tagName) is available")
                        .font(.headline)
                    Text("Open the GitHub release page when you want to update.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button("Open Release Page") {
                        model.openLatestReleasePage()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Dismiss") {
                        model.dismissAvailableUpdateBanner()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Update Available", systemImage: "arrow.down.app")
        }
    }

    private func desktopPreviewUnavailableCard(_ snapshot: LiveStateSnapshot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Desktop mini-map unavailable in fallback/degraded mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if snapshot.degraded {
                    Text("Run Guided Setup for a step-by-step fix.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        liveStateActionButton(.init(label: "Run Guided Setup", prominent: true, handler: {
                            presentOverviewRecoveryGuide(for: snapshot.degradedReason)
                        }))

                        if needsAccessibilityRecoveryHint(for: snapshot.degradedReason) {
                            liveStateActionButton(.init(label: "Open Accessibility Settings", prominent: false, handler: {
                                model.openAccessibilitySettings()
                            }))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Desktop Mini-map", systemImage: "square.grid.3x3")
        }
    }

    private var hasCachedPreciseOverview: Bool {
        !model.overviewDisplayPreviews.isEmpty || !model.overviewDisplaySections.isEmpty
    }

    private func shouldShowPreciseOverview(for snapshot: LiveStateSnapshot) -> Bool {
        if snapshot.source == .yabai && !snapshot.degraded {
            return true
        }
        return snapshot.source == .yabai && snapshot.degraded && hasCachedPreciseOverview
    }

    private func shouldShowStaleOverviewNotice(for snapshot: LiveStateSnapshot) -> Bool {
        snapshot.degraded && snapshot.source == .yabai && hasCachedPreciseOverview
    }

    private func desktopPreviewCard(_ snapshot: LiveStateSnapshot, scrollProxy: ScrollViewProxy) -> some View {
        let previews = model.overviewDisplayPreviews
        let maxDisplayArea = previews
            .map { max($0.frameW, 1) * max($0.frameH, 1) }
            .max() ?? 1
        let cardScale = miniMapCardScale(previews: previews, maxDisplayArea: maxDisplayArea)
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if previews.isEmpty {
                    Text("No preview available for current displays.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Displays sit side by side when they fit, and wrap when they don't.
                    WrappingFlowLayout(horizontalSpacing: Self.miniMapDisplaySpacing, verticalSpacing: 12) {
                        ForEach(previews) { display in
                            let cardWidth = (previewDesktopCardMinimumWidth(for: display, maxDisplayArea: maxDisplayArea) * cardScale).rounded(.down)
                            VStack(alignment: .leading, spacing: 6) {
                                Label(display.name, systemImage: display.focused ? "display.and.arrow.down" : "display")
                                    .font(.caption.weight(.semibold))

                                WrappingFlowLayout(horizontalSpacing: Self.miniMapCardSpacing, verticalSpacing: Self.miniMapCardSpacing) {
                                    ForEach(display.desktops) { desktop in
                                        OverviewDesktopPreviewCard(
                                        desktop: desktop,
                                        displayAspectRatio: display.aspectRatio,
                                        selectedWindowID: selectedWindowID,
                                        onDesktopSelect: { desktopIndex in
                                            model.focusDesktop(index: desktopIndex)
                                        },
                                        onDesktopTilingChange: { desktopIndex, enabled in
                                            model.setDesktopTilingEnabled(spaceIndex: desktopIndex, enabled: enabled)
                                        },
                                        onWindowActivate: { windowID, desktopIndex in
                                            selectedWindowID = windowID
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                scrollProxy.scrollTo("overview-window-\(windowID)", anchor: .center)
                                            }
                                            model.focusWindow(windowID: windowID, desktopIndex: desktopIndex)
                                        }
                                        )
                                        .frame(width: cardWidth)
                                    }
                                }
                            }
                            .padding(Self.miniMapDisplayPadding)
                            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { miniMapWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { miniMapWidth = $0 }
                }
            )
        } label: {
            HStack(spacing: 8) {
                Label("Desktop Mini-map", systemImage: "square.grid.3x3")
                Spacer(minLength: 8)
                Button("Open MegaMap") {
                    model.presentMegamap()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("See every desktop as a real screenshot.")
            }
        }
    }

    private static let miniMapDisplaySpacing: CGFloat = 12
    private static let miniMapCardSpacing: CGFloat = 8
    private static let miniMapDisplayPadding: CGFloat = 8

    /// Grows the desktop cards together, up to 1.6 times their base size, when every desktop fits
    /// on one row with room to spare. Otherwise cards keep their base size and wrap.
    private func miniMapCardScale(previews: [OverviewDisplayPreview], maxDisplayArea: Double) -> CGFloat {
        guard miniMapWidth > 0, !previews.isEmpty else { return 1 }
        var fixedWidth = CGFloat(previews.count - 1) * Self.miniMapDisplaySpacing
        var flexibleWidth: CGFloat = 0
        for display in previews {
            let count = CGFloat(max(display.desktops.count, 1))
            fixedWidth += Self.miniMapDisplayPadding * 2 + (count - 1) * Self.miniMapCardSpacing
            flexibleWidth += count * previewDesktopCardMinimumWidth(for: display, maxDisplayArea: maxDisplayArea)
        }
        guard flexibleWidth > 0 else { return 1 }
        let fit = (miniMapWidth - fixedWidth - 1) / flexibleWidth
        return min(1.6, max(1, fit))
    }

    private func degradedBanner(reason: String) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Degraded Mode")
                        .font(.headline)
                    Text(reason)
                        .font(.subheadline)
                    Text("Workspace-precise mapping may be inaccurate. Showing monitor-level fallback counts when needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let liveStateHelp = liveStateHelp(for: reason) {
                        Text(liveStateHelp.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(liveStateHelp.actions, id: \.label) { action in
                                liveStateActionButton(action)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Degraded", systemImage: "minus.circle")
        }
    }

    private func staleOverviewNotice(reason: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
                .font(.caption)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Live data may be temporarily out of date.")
                    .font(.caption.weight(.semibold))
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let liveStateHelp = liveStateHelp(for: reason) {
                    HStack(spacing: 8) {
                        ForEach(liveStateHelp.actions, id: \.label) { action in
                            liveStateActionButton(action)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }

    private func yabaiMapCard(_ snapshot: LiveStateSnapshot) -> some View {
        let runtimeEnabled = model.canRunYabaiRuntimeCommands
        let runtimeDisabledReason = model.yabaiRuntimeControlDisabledReason ?? "Unavailable"
        let sections = model.overviewDisplaySections

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if sections.isEmpty {
                    Text("No displays returned by yabai.")
                        .foregroundStyle(.secondary)
                } else {
                    if !runtimeEnabled {
                        Text("Window controls unavailable: \(runtimeDisabledReason)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(sections) { displaySection in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(displaySection.display.name, systemImage: displaySection.display.focused ? "display.and.arrow.down" : "display")
                                    .font(.headline)
                                Spacer()
                                Text(windowCountText(visible: displaySection.visibleWindowCount, total: displaySection.totalWindowCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if displaySection.spaces.isEmpty {
                                Text("No desktops returned for this display.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(displaySection.spaces) { spaceSection in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Button {
                                                model.focusDesktop(index: spaceSection.space.index)
                                            } label: {
                                                Text(spaceTitle(spaceSection.space))
                                                    .font(.subheadline.weight(.semibold))
                                            }
                                            .buttonStyle(.plain)
                                            .help("Switch to Desktop \(spaceSection.space.index).")
                                            statusPill(spaceSection.tilingEnabled ? "Tiling On" : "Tiling Off", color: spaceSection.tilingEnabled ? .blue : .orange)
                                            Spacer()
                                            Text(windowCountText(visible: spaceSection.visibleWindowCount, total: spaceSection.totalWindowCount))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        if spaceSection.totalWindowCount == 0 {
                                            Text("No windows on this desktop.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            if spaceSection.visibleWindowCount == 0 {
                                                Text("No visible windows on this desktop (Total: \(spaceSection.totalWindowCount)).")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            ForEach(spaceSection.windows) { window in
                                                windowControlRow(
                                                    window: window,
                                                    desktopTilingEnabled: spaceSection.tilingEnabled,
                                                    runtimeEnabled: runtimeEnabled,
                                                    runtimeDisabledReason: runtimeDisabledReason
                                                )
                                            }
                                        }
                                    }
                                    .padding(8)
                                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Displays and Desktops", systemImage: "rectangle.grid.3x2")
        }
    }

    private func fallbackMapCard(_ snapshot: LiveStateSnapshot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if snapshot.fallbackDisplays.isEmpty {
                    Text("Fallback monitor counts unavailable.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.fallbackDisplays) { display in
                        HStack {
                            Label(display.name, systemImage: "display")
                            Spacer()
                            Text("\(display.windowCount) visible windows")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Desktop/window mapping is hidden in fallback mode to avoid misleading precision.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if snapshot.degraded {
                    liveStateActionButton(.init(label: "Run Guided Setup", prominent: true, handler: {
                        presentOverviewRecoveryGuide(for: snapshot.degradedReason)
                    }))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Displays (fallback view)", systemImage: "display.2")
        }
    }

    private func spaceTitle(_ space: SpaceState) -> String {
        var parts: [String] = ["Desktop \(space.index)"]
        if let label = space.label, !label.isEmpty {
            parts.append("“\(label)”")
        }
        if space.focused { parts.append("• Focused") }
        else if space.visible { parts.append("• Visible") }
        return parts.joined(separator: " ")
    }

    private func windowCountText(visible: Int, total: Int) -> String {
        if visible == total {
            return total == 1 ? "1 window" : "\(total) windows"
        }
        return "\(visible) visible · \(total) total"
    }

    private func windowControlRow(
        window: WindowState,
        desktopTilingEnabled: Bool?,
        runtimeEnabled: Bool,
        runtimeDisabledReason: String
    ) -> some View {
        let appRule = model.appTilingBehavior(for: window.app)
        let effectiveFloating = desktopTilingEnabled == false || window.floating
        let trimmedTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .center, spacing: 8) {
            OverviewWindowIconControl(
                window: window,
                runtimeEnabled: runtimeEnabled,
                runtimeDisabledReason: runtimeDisabledReason
            )

            Text(window.app)
                .font(.caption.weight(.semibold))

            if !trimmedTitle.isEmpty {
                Text(trimmedTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if window.focused {
                statusPill("Focused", color: .blue)
            }
            if window.isMinimized {
                statusPill("Minimized", color: .secondary)
            } else if window.isHidden {
                statusPill("Hidden", color: .secondary)
            }
            if appRule != .useDefault {
                statusPill(appRule.displayName, color: .secondary)
                    .help("App rule for \(window.app). Change it from this row's menu or in Behaviors.")
            }

            Button {
                model.toggleWindowFloating(windowID: window.id)
            } label: {
                if window.isRuntimeManageable {
                    statusPill(effectiveFloating ? "Floating" : "Tiled", color: effectiveFloating ? .orange : .blue)
                } else {
                    statusPill("Limited", color: .gray)
                }
            }
            .buttonStyle(.plain)
            .disabled(!runtimeEnabled || !window.isRuntimeManageable)
            .help(
                !window.isRuntimeManageable
                ? "\(window.app) does not expose move/control hooks for this window right now."
                : (runtimeEnabled
                   ? (desktopTilingEnabled == false
                      ? "Floating because tiling is Off on this desktop. Click to tile it anyway."
                      : "Click to switch between floating and tiled.")
                   : runtimeDisabledReason)
            )

            Menu {
                Button("Set Floating") {
                    model.setWindowFloating(windowID: window.id, shouldFloat: true)
                }
                .disabled(effectiveFloating || !runtimeEnabled || !window.isRuntimeManageable)
                Button("Set Tiled") {
                    model.setWindowFloating(windowID: window.id, shouldFloat: false)
                }
                .disabled(!effectiveFloating || !runtimeEnabled || !window.isRuntimeManageable)

                Divider()

                Picker("Rule for \(window.app)", selection: Binding(
                    get: { model.appTilingBehavior(for: window.app) },
                    set: { model.setAppTilingBehavior($0, for: window.app) }
                )) {
                    ForEach(AppTilingBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }

                Toggle("Keep \(window.app) on Top", isOn: Binding(
                    get: { model.appForegroundPolicy(for: window.app) == .keepFrontWhenFloating },
                    set: { model.setAppForegroundPolicy($0 ? .keepFrontWhenFloating : .useDefault, for: window.app) }
                ))
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedWindowID = window.id
        }
        .onTapGesture(count: 2) {
            selectedWindowID = window.id
            model.focusWindow(windowID: window.id)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedWindowID == window.id ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selectedWindowID == window.id ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .id("overview-window-\(window.id)")
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private struct InlineAction {
        let label: String
        let prominent: Bool
        let handler: () -> Void
    }

    private struct LiveStateHelp {
        let message: String
        let actions: [InlineAction]
    }

    private func liveStateHelp(for message: String) -> LiveStateHelp? {
        let normalized = message.lowercased()

        if normalized.contains("not installed yet") || normalized.contains("no such file or directory") {
            return LiveStateHelp(
                message: "TilePilot cannot show the full desktop map until its local yabai/skhd components are ready. Guided Setup will prepare them automatically.",
                actions: [
                    .init(label: "Run Guided Setup", prominent: true, handler: { model.presentSetupGuide() }),
                    .init(label: "Recheck", prominent: false, handler: { Task { await model.refreshLiveState() } }),
                ]
            )
        }

        if normalized.contains("not running")
            || normalized.contains("message socket")
            || normalized.contains("could not connect")
            || normalized.contains("failed to connect to socket")
            || normalized.contains("socket is unavailable")
            || normalized.contains("socket unavailable") {
            return LiveStateHelp(
                message: "TilePilot cannot talk to yabai yet. Start window control from Guided Setup, then approve any yabai/skhd Accessibility prompt macOS shows.",
                actions: [
                    .init(label: "Run Guided Setup", prominent: true, handler: {
                        presentOverviewRecoveryGuide(for: message)
                    }),
                    .init(label: "Open Accessibility Settings", prominent: false, handler: {
                        model.openAccessibilitySettings()
                    }),
                    .init(label: model.primarySetupAction == .reviewAccessibility ? model.primarySetupActionLabel : "Start Window Control", prominent: false, handler: {
                        if model.primarySetupAction == .startHelperServices || model.primarySetupAction == .reviewAccessibility {
                            model.performPrimarySetupAction()
                        } else {
                            model.startWindowControlBestEffort()
                        }
                    }),
                    .init(label: "Recheck", prominent: false, handler: { Task { await model.refreshLiveState() } }),
                ]
            )
        }

        if normalized.contains("permission") && normalized.contains("denied") {
            return LiveStateHelp(
                message: "macOS denied a yabai/skhd permission TilePilot needs for window control. Open Guided Setup and approve the exact Accessibility entry macOS names.",
                actions: [
                    .init(label: "Run Guided Setup", prominent: true, handler: {
                        presentOverviewRecoveryGuide(for: message)
                    }),
                    .init(label: "Open Accessibility Settings", prominent: false, handler: {
                        model.openAccessibilitySettings()
                    }),
                    .init(label: "Recheck", prominent: false, handler: { Task { await model.refreshLiveState() } }),
                ]
            )
        }

        return nil
    }

    private func needsAccessibilityRecoveryHint(for message: String?) -> Bool {
        guard let message else { return false }
        let normalized = message.lowercased()
        return normalized.contains("socket")
            || normalized.contains("could not connect")
            || normalized.contains("failed to connect")
            || normalized.contains("permission")
    }

    private func presentOverviewRecoveryGuide(for degradedReason: String?) {
        if needsAccessibilityRecoveryHint(for: degradedReason) {
            if model.hasIncompleteEssentialSetupGuideSteps {
                model.presentSetupGuide(source: .manual, startingAt: .accessibility)
            } else {
                model.presentSetupGuide(source: .manual, startingAt: .accessibility)
            }
            return
        }

        if model.hasIncompleteEssentialSetupGuideSteps {
            model.presentSetupGuide(source: .manual, startingAt: .accessibility)
        } else {
            model.presentSetupGuide()
        }
    }

    private func previewDesktopCardMinimumWidth(for display: OverviewDisplayPreview, maxDisplayArea: Double) -> CGFloat {
        guard maxDisplayArea > 1 else { return 300 }
        let area = max(display.frameW, 1) * max(display.frameH, 1)
        let normalized = max(0.35, min(1.0, area / maxDisplayArea))
        let scale = sqrt(normalized)
        let minWidth: Double = 240
        let maxWidth: Double = 340
        return CGFloat(minWidth + (maxWidth - minWidth) * scale)
    }

    @ViewBuilder
    private func liveStateActionButton(_ action: InlineAction) -> some View {
        if action.prominent {
            Button(action.label, action: action.handler)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(action.label, action: action.handler)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
