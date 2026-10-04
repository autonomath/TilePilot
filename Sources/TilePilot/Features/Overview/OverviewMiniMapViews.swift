import AppKit
import SwiftUI

private enum OverviewMiniMapHeaderMetrics {
    static let controlHeight: CGFloat = 28
}

struct HoveredMiniWindowBubbleState: Equatable {
    let windowID: Int
    let title: String
    let iconFrame: CGRect
}

struct OverviewMiniMapTitleBubble: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: bubbleWidth, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.10, opacity: 0.98))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.7)
            )
            .shadow(color: Color.black.opacity(0.22), radius: 6, x: 0, y: 2)
            .compositingGroup()
    }

    private var bubbleWidth: CGFloat {
        let maxWidth: CGFloat = 320
        let minWidth: CGFloat = 56
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let singleLineWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width) + 14
        return min(max(minWidth, singleLineWidth), maxWidth)
    }
}

struct OverviewWindowIconControl: View {
    @EnvironmentObject private var model: AppModel

    let window: WindowState
    let runtimeEnabled: Bool
    let runtimeDisabledReason: String

    private var controlSize: CGFloat {
        16
    }

    private var keepOnTopEnabledForApp: Bool {
        model.appForegroundPolicy(for: window.app) == .keepFrontWhenFloating
    }

    private var neverAutoTileEnabledForApp: Bool {
        model.isNeverAutoTileEnabled(for: window.app)
    }

    var body: some View {
        iconView
            .frame(width: 16, height: 16)
        .frame(width: controlSize, height: controlSize, alignment: .center)
        .contextMenu {
            Button("Focus Window") {
                model.focusWindow(windowID: window.id)
            }
            .disabled(!runtimeEnabled)

            Divider()

            Button(window.floating ? "Set Tiled" : "Set Floating") {
                model.toggleWindowFloating(windowID: window.id)
            }
            .disabled(!runtimeEnabled || !window.isRuntimeManageable)

            Button("Set Floating") {
                model.setWindowFloating(windowID: window.id, shouldFloat: true)
            }
            .disabled(!runtimeEnabled || !window.isRuntimeManageable || window.floating)

            Button("Set Tiled") {
                model.setWindowFloating(windowID: window.id, shouldFloat: false)
            }
            .disabled(!runtimeEnabled || !window.isRuntimeManageable || !window.floating)

            Divider()

            Toggle(isOn: Binding(
                get: { keepOnTopEnabledForApp },
                set: { enabled in
                    model.setAppForegroundPolicy(enabled ? .keepFrontWhenFloating : .useDefault, for: window.app)
                }
            )) {
                Text("Keep \(window.app) on Top")
            }

            Toggle(isOn: Binding(
                get: { neverAutoTileEnabledForApp },
                set: { enabled in
                    model.setNeverAutoTileEnabled(enabled, for: window.app)
                }
            )) {
                Text("Never Auto-Tile \(window.app)")
            }

            if !runtimeEnabled {
                Divider()
                Text("Unavailable: \(runtimeDisabledReason)")
            } else if !window.isRuntimeManageable {
                Divider()
                Text("Limited: this window cannot be floated/tiled right now.")
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = AppIconResolver.shared.icon(forAppNamed: window.app, size: 16) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "app")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(1)
        }
    }
}

struct OverviewDesktopPreviewCard: View {
    @EnvironmentObject private var model: AppModel

    let desktop: OverviewDesktopPreview
    let displayAspectRatio: Double
    let selectedWindowID: Int?
    let onDesktopSelect: (Int) -> Void
    let onDesktopTilingChange: (Int, Bool) -> Void
    let onWindowActivate: (Int, Int) -> Void

    @State private var hoveredBubble: HoveredMiniWindowBubbleState?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("#\(desktop.desktopIndex)")
                        .font(.subheadline.weight(.semibold))
                        .frame(height: OverviewMiniMapHeaderMetrics.controlHeight)

                    Button("Jump") {
                        onDesktopSelect(desktop.desktopIndex)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(height: OverviewMiniMapHeaderMetrics.controlHeight)
                    .help("Switch to Desktop #\(desktop.desktopIndex).")

                    if desktop.focused {
                        Text("Focused")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                    } else if desktop.visible {
                        Text("Visible")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Text("Tiling")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    OverviewMiniMapTilingToggle(
                        isOn: desktop.tilingEnabled,
                        onSet: { onDesktopTilingChange(desktop.desktopIndex, $0) }
                    )
                    .frame(width: 92)
                }
            }

            GeometryReader { proxy in
                let size = proxy.size

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.94))
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.black.opacity(0.12), lineWidth: 1)

                    ForEach(desktop.windows) { window in
                        OverviewMiniWindowFrameLayer(
                            window: window,
                            canvasSize: size,
                            isSelected: selectedWindowID == window.id,
                            isHovered: hoveredBubble?.windowID == window.id
                        )
                    }

                    ForEach(desktop.windows) { window in
                        OverviewMiniWindowIconButton(
                            window: window,
                            canvasSize: size,
                            onActivate: onWindowActivate,
                            onHoverChanged: { hoveredBubble = $0 }
                        )
                    }

                    if model.miniMapHoverTitlesEnabled, let hoveredBubble {
                        OverviewMiniMapTitleBubble(title: hoveredBubble.title)
                            .offset(
                                x: hoveredBubble.iconFrame.maxX + 10,
                                y: hoveredBubble.iconFrame.maxY + 4
                            )
                            .allowsHitTesting(false)
                            .zIndex(1000)
                    }
                }
            }
            .aspectRatio(max(displayAspectRatio, 0.1), contentMode: .fit)
            .frame(maxWidth: .infinity)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .zIndex(hoveredBubble == nil ? 0 : 100)
    }
}

private struct OverviewMiniMapTilingToggle: View {
    let isOn: Bool
    let onSet: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            toggleButton(title: "On", isSelected: isOn) {
                if !isOn { onSet(true) }
            }
            toggleButton(title: "Off", isSelected: !isOn) {
                if isOn { onSet(false) }
            }
        }
        .padding(2)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.08))
        )
        .overlay(
            Capsule()
                .stroke(Color.black.opacity(0.14), lineWidth: 1)
        )
        .frame(height: OverviewMiniMapHeaderMetrics.controlHeight)
    }

    private func toggleButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? Color.white : Color.black.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.blue.opacity(0.9) : Color.white.opacity(0.82))
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

private struct OverviewMiniWindowFrameLayer: View {
    let window: OverviewWindowPreview
    let canvasSize: CGSize
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        let frame = OverviewMiniMapGeometry.frame(for: window, in: canvasSize)
        let palette = MapWindowPalette.colors(
            windowID: window.id,
            isFloating: window.floating,
            usesLimitedVisualStyle: window.usesLimitedVisualStyle,
            isFocused: window.focused,
            isSelected: isSelected,
            preferredWarmIndex: window.warmPaletteIndex
        )
        let baseLineWidth: CGFloat = isSelected ? 2 : 1.2
        let lineWidth = isHovered ? baseLineWidth * 3 : baseLineWidth

        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 4)
                .fill(palette.fill)
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 4)
                .stroke(palette.border.opacity(window.visible ? 1 : 0.72), lineWidth: lineWidth)
                .allowsHitTesting(false)

            if window.focused {
                Circle()
                    .fill(palette.border)
                    .frame(width: 5, height: 5)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .offset(x: frame.minX, y: frame.minY)
    }
}

private struct OverviewMiniWindowIconButton: View {
    @EnvironmentObject private var model: AppModel

    let window: OverviewWindowPreview
    let canvasSize: CGSize
    let onActivate: (Int, Int) -> Void
    let onHoverChanged: (HoveredMiniWindowBubbleState?) -> Void

    var body: some View {
        let frame = OverviewMiniMapGeometry.frame(for: window, in: canvasSize)
        let iconInset: CGFloat = 3
        let iconSize = baseIconDimension(for: frame.size)
        let iconFrame = OverviewMiniMapGeometry.iconFrame(
            for: window,
            iconSize: iconSize,
            inset: iconInset,
            in: canvasSize
        )
        let runtimeEnabled = model.canRunYabaiRuntimeCommands
        let runtimeDisabledReason = model.yabaiRuntimeControlDisabledReason ?? "Unavailable"
        let hoverTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? window.app : window.title

        Button {
            onActivate(window.id, window.desktopIndex)
        } label: {
            Group {
                if let icon = AppIconResolver.shared.icon(forAppNamed: window.app, size: iconSize) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(systemName: "app")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .opacity(window.visible ? 1 : 0.75)
        }
        .buttonStyle(.plain)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                onHoverChanged(HoveredMiniWindowBubbleState(
                    windowID: window.id,
                    title: hoverTitle,
                    iconFrame: iconFrame
                ))
                if model.miniMapHoverTitlesEnabled {
                    model.incrementMiniMapHoverUpdates()
                }
            case .ended:
                onHoverChanged(nil)
            }
        }
        .frame(width: iconFrame.width, height: iconFrame.height)
        .position(x: iconFrame.midX, y: iconFrame.midY)
        .contextMenu {
            Button("Focus Window") {
                model.focusWindow(windowID: window.id, desktopIndex: window.desktopIndex)
            }
            .disabled(!runtimeEnabled)

            Divider()

            Button(window.floating ? "Set Tiled" : "Set Floating") {
                model.toggleWindowFloating(windowID: window.id)
            }
            .disabled(!runtimeEnabled || !window.runtimeManageable)

            Button("Set Floating") {
                model.setWindowFloating(windowID: window.id, shouldFloat: true)
            }
            .disabled(!runtimeEnabled || !window.runtimeManageable || window.floating)

            Button("Set Tiled") {
                model.setWindowFloating(windowID: window.id, shouldFloat: false)
            }
            .disabled(!runtimeEnabled || !window.runtimeManageable || !window.floating)

            Divider()

            Toggle(isOn: Binding(
                get: { model.appForegroundPolicy(for: window.app) == .keepFrontWhenFloating },
                set: { enabled in
                    model.setAppForegroundPolicy(enabled ? .keepFrontWhenFloating : .useDefault, for: window.app)
                }
            )) {
                Text("Keep \(window.app) on Top")
            }

            Toggle(isOn: Binding(
                get: { model.isNeverAutoTileEnabled(for: window.app) },
                set: { enabled in
                    model.setNeverAutoTileEnabled(enabled, for: window.app)
                }
            )) {
                Text("Never Auto-Tile \(window.app)")
            }

            if !runtimeEnabled {
                Divider()
                Text("Unavailable: \(runtimeDisabledReason)")
            } else if !window.runtimeManageable {
                Divider()
                Text("Limited: this window cannot be floated/tiled right now.")
            }
        }
    }

    private func baseIconDimension(for size: CGSize) -> CGFloat {
        let base = min(size.width, size.height) * 0.52 * 1.5
        return max(12, min(27, base))
    }
}
