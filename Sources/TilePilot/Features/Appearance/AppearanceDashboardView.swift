import SwiftUI

/// Overlay and spacing settings on the left, and a live preview on the right that redraws as
/// they change, so each setting shows its effect without an explanation.
struct AppearanceDashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        overlaysCard
                        spacingCard
                    }
                    .frame(width: 400)

                    previewCard
                        .frame(maxWidth: .infinity)
                }
                .padding()
            }
            .navigationTitle("TilePilot")
            .task { await model.refreshWindowBehaviorConfig() }
        }
    }

    private var overlaysCard: some View {
        let anyOverlay = model.showWindowBadgeOverlay || model.showWindowOutlineOverlay
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Drawn on your desktops. The mini-map and MegaMap keep their own colors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Window badges")
                        Toggle("Window badges", isOn: Binding(
                            get: { model.showWindowBadgeOverlay },
                            set: { model.setWindowBadgeOverlayEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    GridRow {
                        Text("Window outlines")
                        Toggle("Window outlines", isOn: Binding(
                            get: { model.showWindowOutlineOverlay },
                            set: { model.setWindowOutlineOverlayEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    GridRow {
                        Text("Outline width")
                        AppearanceIntegerField(
                            title: "Outline width",
                            unit: "px",
                            value: Binding(
                                get: { Int(model.windowOutlineOverlayBaseWidth.rounded()) },
                                set: { model.setWindowOutlineOverlayBaseWidth(Double($0)) }
                            ),
                            range: 1 ... 6
                        )
                        .disabled(!model.showWindowOutlineOverlay)
                    }
                    GridRow {
                        Text("Tiled windows")
                        colorPicker(
                            "Tiled windows",
                            color: model.tiledOverlayAccentColor,
                            set: { model.setTiledOverlayAccentColor($0) }
                        )
                        .disabled(!anyOverlay)
                    }
                    GridRow {
                        Text("Floating windows")
                        colorPicker(
                            "Floating windows",
                            color: model.floatingOverlayAccentColor,
                            set: { model.setFloatingOverlayAccentColor($0) }
                        )
                        .disabled(!anyOverlay)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Overlays", systemImage: "square.stack.3d.up")
        }
    }

    private var spacingCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Applies to every tiled desktop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Screen edge padding")
                        AppearanceIntegerField(
                            title: "Screen edge padding",
                            unit: "pt",
                            value: Binding(
                                get: { model.windowBehaviorPolicyDraft.outerPadding },
                                set: { model.updateOuterPaddingDraft($0) }
                            ),
                            range: 0 ... 100
                        )
                    }
                    GridRow {
                        Text("Gap between tiled windows")
                        AppearanceIntegerField(
                            title: "Gap between tiled windows",
                            unit: "pt",
                            value: Binding(
                                get: { model.windowBehaviorPolicyDraft.windowGap },
                                set: { model.updateWindowGapDraft($0) }
                            ),
                            range: 0 ... 100
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Tiling Spacing", systemImage: "rectangle.split.3x1")
        }
    }

    private var previewCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                AppearanceOverlayPreview(
                    showBadges: model.showWindowBadgeOverlay,
                    showOutlines: model.showWindowOutlineOverlay,
                    outlineWidth: CGFloat(model.windowOutlineOverlayBaseWidth),
                    tiledColor: model.tiledOverlayAccentColor.swiftUIColor,
                    floatingColor: model.floatingOverlayAccentColor.swiftUIColor,
                    edgePadding: CGFloat(model.windowBehaviorPolicyDraft.outerPadding),
                    gap: CGFloat(model.windowBehaviorPolicyDraft.windowGap)
                )
                Text("Spacing is drawn to scale for a display \(Int(AppearanceOverlayPreview.referenceScreenWidth)) points wide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Preview", systemImage: "eye")
        }
    }

    private func colorPicker(_ title: String, color: OverlayAccentColor, set: @escaping @MainActor (OverlayAccentColor) -> Void) -> some View {
        ColorPicker(title, selection: Binding(
            get: { color.swiftUIColor },
            set: { newColor in
                if let converted = OverlayAccentColor.from(swiftUIColor: newColor) {
                    set(converted)
                }
            }
        ), supportsOpacity: false)
        .labelsHidden()
    }
}

private struct AppearanceIntegerField: View {
    let title: String
    let unit: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 0
        formatter.maximum = 100
        return formatter
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            TextField(title, value: $value, formatter: Self.formatter)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 52)

            Text(unit)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Stepper(title, value: $value, in: range)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

/// A small desktop with three tiled windows and one floating window, drawn with the current
/// overlay settings. Padding and gaps are scaled from a reference display width.
struct AppearanceOverlayPreview: View {
    static let referenceScreenWidth: CGFloat = 1440

    let showBadges: Bool
    let showOutlines: Bool
    let outlineWidth: CGFloat
    let tiledColor: Color
    let floatingColor: Color
    let edgePadding: CGFloat
    let gap: CGFloat

    private static let menuBarHeight: CGFloat = 12
    private static let desktopTop = Color(red: 0.078, green: 0.141, blue: 0.255)
    private static let desktopBottom = Color(red: 0.106, green: 0.102, blue: 0.149)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let scale = size.width / Self.referenceScreenWidth
            let padding = edgePadding * scale
            let gapWidth = gap * scale
            let area = CGRect(
                x: padding,
                y: Self.menuBarHeight + padding,
                width: max(size.width - padding * 2, 1),
                height: max(size.height - Self.menuBarHeight - padding * 2, 1)
            )
            let leftWidth = (area.width - gapWidth) * 0.55
            let left = CGRect(x: area.minX, y: area.minY, width: leftWidth, height: area.height)
            let rightWidth = area.width - leftWidth - gapWidth
            let rightTopHeight = (area.height - gapWidth) / 2
            let rightTop = CGRect(x: left.maxX + gapWidth, y: area.minY, width: rightWidth, height: rightTopHeight)
            let rightBottom = CGRect(x: rightTop.minX, y: rightTop.maxY + gapWidth, width: rightWidth, height: area.height - rightTopHeight - gapWidth)
            let floating = CGRect(x: size.width * 0.29, y: size.height * 0.34, width: size.width * 0.34, height: size.height * 0.42)

            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Self.desktopTop, Self.desktopBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: size.width, height: Self.menuBarHeight)
                previewWindow("Mail", content: .document, frame: left, isFloating: false)
                previewWindow("Notes", content: .notes, frame: rightTop, isFloating: false)
                previewWindow("Safari", content: .browser, frame: rightBottom, isFloating: false)
                previewWindow("Terminal", content: .terminal, frame: floating, isFloating: true)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of window overlays and tiling spacing")
    }

    private enum WindowContent {
        case document, notes, browser, terminal

        var titleBar: Color {
            switch self {
            case .terminal: return Color(red: 0.106, green: 0.141, blue: 0.200)
            case .notes: return Color(red: 0.953, green: 0.918, blue: 0.816)
            case .document, .browser: return Color(red: 0.906, green: 0.925, blue: 0.953)
            }
        }

        var titleText: Color {
            self == .terminal ? Color(red: 0.663, green: 0.714, blue: 0.788) : Color(red: 0.294, green: 0.353, blue: 0.439)
        }

        var body: Color {
            switch self {
            case .terminal: return Color(red: 0.055, green: 0.082, blue: 0.133)
            case .notes: return Color(red: 1, green: 0.973, blue: 0.890)
            case .document, .browser: return Color(red: 0.969, green: 0.976, blue: 0.988)
            }
        }
    }

    private func previewWindow(_ title: String, content: WindowContent, frame: CGRect, isFloating: Bool) -> some View {
        let accent = isFloating ? floatingColor : tiledColor
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(content.titleText)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Circle().fill(Color(red: 1, green: 0.373, blue: 0.341)).frame(width: 5, height: 5)
                    Circle().fill(Color(red: 0.996, green: 0.737, blue: 0.180)).frame(width: 5, height: 5)
                    Circle().fill(Color(red: 0.157, green: 0.784, blue: 0.251)).frame(width: 5, height: 5)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
            }
            .frame(height: 15)
            .background(content.titleBar)

            windowContent(content, width: frame.width)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(content.body)
                .clipped()
        }
        .clipShape(shape)
        .overlay(
            shape.stroke(showOutlines ? accent : Color.black.opacity(0.35), lineWidth: showOutlines ? max(outlineWidth, 1) : 0.5)
        )
        .overlay(alignment: .top) {
            if showBadges {
                Capsule()
                    .fill(accent.opacity(0.95))
                    .frame(width: 30, height: 7)
                    .overlay(Capsule().stroke(Color.white.opacity(0.36), lineWidth: 0.6))
                    .opacity(0.8)
                    .padding(.top, 4)
            }
        }
        .shadow(color: .black.opacity(isFloating ? 0.45 : 0.2), radius: isFloating ? 8 : 2, y: isFloating ? 4 : 1)
        .frame(width: max(frame.width, 1), height: max(frame.height, 1))
        .offset(x: frame.minX, y: frame.minY)
    }

    @ViewBuilder
    private func windowContent(_ content: WindowContent, width: CGFloat) -> some View {
        let lineWidth = max(width - 16, 1)
        switch content {
        case .document:
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array([0.82, 0.55, 0.7, 0.42, 0.76, 0.6, 0.5, 0.8, 0.45, 0.68].enumerated()), id: \.offset) { _, fraction in
                    Capsule()
                        .fill(Color(red: 0.55, green: 0.66, blue: 0.86).opacity(0.45))
                        .frame(width: lineWidth * fraction, height: 3)
                }
            }
        case .notes:
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array([0.7, 0.85, 0.5, 0.78, 0.62].enumerated()), id: \.offset) { _, fraction in
                    Capsule()
                        .fill(Color(red: 0.910, green: 0.851, blue: 0.659))
                        .frame(width: lineWidth * fraction, height: 3)
                }
            }
        case .browser:
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.812, green: 0.890, blue: 1), Color(red: 0.910, green: 0.863, blue: 1)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(height: 34)
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color(red: 0.890, green: 0.914, blue: 0.949))
                            .frame(height: 28)
                    }
                }
            }
        case .terminal:
            VStack(alignment: .leading, spacing: 3) {
                Text("$ make test").foregroundStyle(Color(red: 0.788, green: 0.839, blue: 0.918))
                Text("ok 42 passed").foregroundStyle(Color(red: 0.62, green: 0.88, blue: 0.66))
                Text("$ _").foregroundStyle(Color(red: 0.788, green: 0.839, blue: 0.918))
            }
            .font(.system(size: 9, design: .monospaced))
        }
    }
}
