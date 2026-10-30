import AppKit
import SwiftUI

private enum ExplainerDiagramMetrics {
    static let pairedStageMinWidth: CGFloat = 300
    static let pairedStageMaxWidth: CGFloat = 420
    static let pairedStageSpacing: CGFloat = 16
    static let stageHeight: CGFloat = 150
    static let desktopHeight: CGFloat = 230
}

/// Colors shared with TilePilot's maps and the website: blue outlines for tiled windows, orange
/// for floating ones, light "paper" windows on a dark desktop.
private enum ExplainerPalette {
    static let tiled = Color(red: 0.20, green: 0.50, blue: 0.95)
    static let floating = Color(red: 0.96, green: 0.64, blue: 0.18)
    static let paper = Color(red: 0.969, green: 0.976, blue: 0.988)
    static let titleBar = Color(red: 0.906, green: 0.925, blue: 0.953)
    static let titleText = Color(red: 0.294, green: 0.353, blue: 0.439)
    static let desktopTop = Color(red: 0.078, green: 0.141, blue: 0.255)
    static let desktopMiddle = Color(red: 0.047, green: 0.078, blue: 0.149)
    static let desktopBottom = Color(red: 0.106, green: 0.102, blue: 0.149)
    static let desktopGlowBlue = Color(red: 0.122, green: 0.227, blue: 0.388)
    static let desktopGlowAmber = Color(red: 0.290, green: 0.184, blue: 0.071)
}

/// A plain panel for diagrams without windows.
private struct ExplainerStage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                content
                    .padding(12)
            }
            .frame(maxWidth: .infinity, minHeight: ExplainerDiagramMetrics.stageHeight, maxHeight: ExplainerDiagramMetrics.stageHeight)
        }
    }
}

private struct ExplainerTwoUp<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: ExplainerDiagramMetrics.pairedStageSpacing) {
                leading
                    .frame(minWidth: ExplainerDiagramMetrics.pairedStageMinWidth, maxWidth: ExplainerDiagramMetrics.pairedStageMaxWidth)
                trailing
                    .frame(minWidth: ExplainerDiagramMetrics.pairedStageMinWidth, maxWidth: ExplainerDiagramMetrics.pairedStageMaxWidth)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: ExplainerDiagramMetrics.pairedStageSpacing) {
                leading
                trailing
            }
        }
    }
}

// MARK: - Desktop and windows

private enum ExplainerWindowState {
    case tiled, floating, plain
}

private enum ExplainerWindowContent {
    case document, browser, terminal, notes
}

/// One sample window. `frame` is in fractions of the desktop below its menu bar; later windows
/// sit on top of earlier ones.
private struct ExplainerWindowSpec {
    let title: String
    var content: ExplainerWindowContent = .document
    var tint: Color = .blue
    let frame: CGRect
    var state: ExplainerWindowState = .plain
    var focused = false
}

/// A small desktop like the website's demo: a dark wallpaper, a menu bar strip with an optional
/// label, and sample windows placed by fraction so they fill the space.
private struct ExplainerDesktopStage: View {
    let title: String
    var label: String?
    let windows: [ExplainerWindowSpec]
    /// Where the pointer sits, in fractions of the desktop, and which symbol draws it.
    var cursor: CGPoint?
    var cursorSymbol = "cursorarrow"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if let label {
                        Text(label)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.white.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 18)
                .background(Color.white.opacity(0.06))

                GeometryReader { geometry in
                    let size = geometry.size
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                            ExplainerWindow(spec: window)
                                .frame(width: window.frame.width * size.width, height: window.frame.height * size.height)
                                .offset(x: window.frame.minX * size.width, y: window.frame.minY * size.height)
                        }
                        if let cursor {
                            Image(systemName: cursorSymbol)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1)
                                .offset(x: cursor.x * size.width, y: cursor.y * size.height)
                        }
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, minHeight: ExplainerDiagramMetrics.desktopHeight, maxHeight: ExplainerDiagramMetrics.desktopHeight)
            .background(
                ZStack {
                    LinearGradient(
                        colors: [ExplainerPalette.desktopTop, ExplainerPalette.desktopMiddle, ExplainerPalette.desktopBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    RadialGradient(colors: [ExplainerPalette.desktopGlowBlue, .clear], center: .init(x: 0.15, y: 0), startRadius: 0, endRadius: 220)
                    RadialGradient(colors: [ExplainerPalette.desktopGlowAmber, .clear], center: .init(x: 1, y: 1), startRadius: 0, endRadius: 200)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
        }
    }
}

/// A sample window drawn like a real one: a title bar with the three window buttons, content
/// that suggests the app, and an outline that says whether it is tiled or floating.
private struct ExplainerWindow: View {
    let spec: ExplainerWindowSpec

    private static let documentLines: [CGFloat] = [0.82, 0.55, 0.7, 0.42, 0.76, 0.6, 0.5, 0.8, 0.45, 0.68, 0.58, 0.74]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        VStack(spacing: 0) {
            titleBar
            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(bodyColor)
                .clipped()
        }
        .clipShape(shape)
        .overlay(shape.stroke(borderColor, lineWidth: borderWidth))
        .shadow(color: spec.focused ? borderColor.opacity(0.55) : .clear, radius: 5)
        .shadow(color: .black.opacity(spec.state == .floating ? 0.45 : 0.25), radius: spec.state == .floating ? 8 : 3, y: spec.state == .floating ? 4 : 1)
    }

    /// The three window buttons on the left and the title centered, as macOS draws them.
    private var titleBar: some View {
        ZStack {
            Text(spec.title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .padding(.horizontal, 28)
            HStack(spacing: 3) {
                Circle().fill(Color(red: 1, green: 0.373, blue: 0.341)).frame(width: 5, height: 5)
                Circle().fill(Color(red: 0.996, green: 0.737, blue: 0.180)).frame(width: 5, height: 5)
                Circle().fill(Color(red: 0.157, green: 0.784, blue: 0.251)).frame(width: 5, height: 5)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 15)
        .background(titleBarColor)
    }

    @ViewBuilder
    private var contentView: some View {
        switch spec.content {
        case .document:
            lines(Self.documentLines, color: spec.tint.opacity(0.35))
        case .notes:
            lines([0.7, 0.85, 0.5, 0.78, 0.62, 0.8, 0.55], color: Color(red: 0.910, green: 0.851, blue: 0.659))
        case .browser:
            GeometryReader { geometry in
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.812, green: 0.890, blue: 1), Color(red: 0.910, green: 0.863, blue: 1)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(height: geometry.size.height * 0.4)
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Color(red: 0.890, green: 0.914, blue: 0.949))
                        }
                    }
                }
            }
            .padding(7)
        case .terminal:
            VStack(alignment: .leading, spacing: 2) {
                Text("$ make test").foregroundStyle(Color(red: 0.788, green: 0.839, blue: 0.918))
                Text("ok 42 passed").foregroundStyle(Color(red: 0.62, green: 0.88, blue: 0.66))
                Text("$ _").foregroundStyle(Color(red: 0.788, green: 0.839, blue: 0.918))
            }
            .font(.system(size: 8, design: .monospaced))
            .padding(7)
        }
    }

    private func lines(_ widths: [CGFloat], color: Color) -> some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * width, height: 3)
                }
            }
        }
        .padding(7)
    }

    private var bodyColor: Color {
        switch spec.content {
        case .terminal: return Color(red: 0.055, green: 0.082, blue: 0.133)
        case .notes: return Color(red: 1, green: 0.973, blue: 0.890)
        case .document, .browser: return ExplainerPalette.paper
        }
    }

    private var titleBarColor: Color {
        switch spec.content {
        case .terminal: return Color(red: 0.106, green: 0.141, blue: 0.200)
        case .notes: return Color(red: 0.953, green: 0.918, blue: 0.816)
        case .document, .browser: return ExplainerPalette.titleBar
        }
    }

    private var titleColor: Color {
        spec.content == .terminal ? Color(red: 0.663, green: 0.714, blue: 0.788) : ExplainerPalette.titleText
    }

    private var borderColor: Color {
        switch spec.state {
        case .tiled: return ExplainerPalette.tiled
        case .floating: return ExplainerPalette.floating
        case .plain: return spec.focused ? Color.accentColor : Color.black.opacity(0.35)
        }
    }

    private var borderWidth: CGFloat {
        if spec.focused { return 2.5 }
        return spec.state == .plain ? 1 : 1.5
    }
}

// MARK: - Diagrams

struct DesktopAutoTilingExplainerDiagram: View {
    var body: some View {
        ExplainerTwoUp {
            ExplainerDesktopStage(title: "On: windows tile", label: "Desktop 1 · Tiling On", windows: [
                .init(title: "Mail", tint: .blue, frame: CGRect(x: 0, y: 0, width: 0.49, height: 1), state: .tiled, focused: true),
                .init(title: "Notes", content: .notes, frame: CGRect(x: 0.51, y: 0, width: 0.49, height: 0.49), state: .tiled),
                .init(title: "Safari", content: .browser, frame: CGRect(x: 0.51, y: 0.51, width: 0.49, height: 0.49), state: .tiled),
            ])
        } trailing: {
            ExplainerDesktopStage(title: "Off: windows float", label: "Desktop 1 · Tiling Off", windows: [
                .init(title: "Mail", tint: .blue, frame: CGRect(x: 0.02, y: 0.24, width: 0.48, height: 0.64), state: .floating),
                .init(title: "Safari", content: .browser, frame: CGRect(x: 0.5, y: 0.4, width: 0.48, height: 0.58), state: .floating),
                .init(title: "Notes", content: .notes, frame: CGRect(x: 0.36, y: 0.02, width: 0.4, height: 0.34), state: .floating, focused: true),
            ])
        }
    }
}

struct AppRulesExplainerDiagram: View {
    var body: some View {
        ExplainerTwoUp {
            ExplainerDesktopStage(title: "Global default", label: "Default: Float", windows: [
                .init(title: "Terminal", content: .terminal, frame: CGRect(x: 0.04, y: 0.06, width: 0.56, height: 0.58), state: .floating),
                .init(title: "Notes", content: .notes, frame: CGRect(x: 0.4, y: 0.36, width: 0.52, height: 0.6), state: .floating),
            ])
        } trailing: {
            ExplainerDesktopStage(title: "App rule overrides it", label: "Chrome: Always Tile", windows: [
                .init(title: "Chrome", content: .browser, frame: CGRect(x: 0, y: 0, width: 1, height: 1), state: .tiled, focused: true),
                .init(title: "Slack", tint: .purple, frame: CGRect(x: 0.5, y: 0.08, width: 0.44, height: 0.48), state: .floating),
                .init(title: "Finder", tint: .gray, frame: CGRect(x: 0.36, y: 0.46, width: 0.42, height: 0.48), state: .floating),
            ])
        }
    }
}

struct HoverFocusExplainerDiagram: View {
    var body: some View {
        ExplainerTwoUp {
            ExplainerDesktopStage(title: "Hover moves focus", label: "Hover Focus", windows: [
                .init(title: "Mail", tint: .blue, frame: CGRect(x: 0, y: 0, width: 0.49, height: 1)),
                .init(title: "Safari", content: .browser, frame: CGRect(x: 0.51, y: 0, width: 0.49, height: 1), focused: true),
            ], cursor: CGPoint(x: 0.72, y: 0.55))
        } trailing: {
            ExplainerDesktopStage(title: "Cursor follows focus", label: "Cursor Follows Focus", windows: [
                .init(title: "Mail", tint: .blue, frame: CGRect(x: 0, y: 0, width: 0.49, height: 1), focused: true),
                .init(title: "Safari", content: .browser, frame: CGRect(x: 0.51, y: 0, width: 0.49, height: 1)),
            ], cursor: CGPoint(x: 0.2, y: 0.5), cursorSymbol: "cursorarrow.motionlines")
        }
    }
}

struct DesktopScrubExplainerDiagram: View {
    var body: some View {
        ExplainerTwoUp {
            ExplainerStage(title: "Hold the trigger keys") {
                VStack(spacing: 12) {
                    HStack(spacing: 6) {
                        scrubKey("⇧")
                        scrubKey("⌃")
                        scrubKey("⌥")
                        Image(systemName: "cursorarrow.motionlines")
                            .font(.title3)
                            .padding(.leading, 8)
                        Text("Move left or right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    desktops(active: 0)
                }
            }
        } trailing: {
            ExplainerStage(title: "Let go and settle there") {
                VStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.and.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ExplainerPalette.tiled)
                        Text("macOS settles on the desktop you scrubbed to")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    desktops(active: 1)
                }
            }
        }
    }

    private func scrubKey(_ symbol: String) -> some View {
        Text(symbol)
            .font(.subheadline.weight(.semibold))
            .frame(width: 30, height: 26)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
    }

    private func desktops(active: Int) -> some View {
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                VStack(spacing: 4) {
                    ExplainerDesktopThumbnail(variant: index)
                        .frame(width: 92, height: 56)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(index == active ? ExplainerPalette.tiled : Color.secondary.opacity(0.3), lineWidth: index == active ? 2.5 : 1)
                        )
                        .shadow(color: index == active ? ExplainerPalette.tiled.opacity(0.5) : .clear, radius: 5)
                    Text("Desktop \(index + 1)")
                        .font(.caption2.weight(index == active ? .semibold : .regular))
                        .foregroundStyle(index == active ? .primary : .secondary)
                }
            }
        }
    }
}

/// A tiny desktop with a few windows, for diagrams about switching desktops.
private struct ExplainerDesktopThumbnail: View {
    let variant: Int

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [ExplainerPalette.desktopTop, ExplainerPalette.desktopMiddle, ExplainerPalette.desktopBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                    VStack(spacing: 0) {
                        Rectangle().fill(ExplainerPalette.titleBar).frame(height: 4)
                        Rectangle().fill(ExplainerPalette.paper)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                    .frame(width: frame.width * size.width, height: frame.height * size.height)
                    .offset(x: frame.minX * size.width, y: frame.minY * size.height)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var frames: [CGRect] {
        switch variant % 3 {
        case 0: return [CGRect(x: 0.06, y: 0.12, width: 0.42, height: 0.78), CGRect(x: 0.52, y: 0.12, width: 0.42, height: 0.78)]
        case 1: return [CGRect(x: 0.1, y: 0.14, width: 0.56, height: 0.6), CGRect(x: 0.4, y: 0.32, width: 0.5, height: 0.56)]
        default: return [CGRect(x: 0.06, y: 0.12, width: 0.88, height: 0.78)]
        }
    }
}

struct RightClickMenuExplainerDiagram: View {
    var body: some View {
        ExplainerStage(title: "Pin items here") {
            VStack(alignment: .trailing, spacing: 0) {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 14, height: 14)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    Image(systemName: "wifi")
                    Text("Tue 9:41 AM")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background(
                    LinearGradient(
                        colors: [ExplainerPalette.desktopTop, ExplainerPalette.desktopMiddle],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    menuRow("Float All Windows", pinned: true)
                    menuRow("Arrange Windows into a Floating Grid", pinned: true)
                    Divider().padding(.vertical, 2)
                    menuRow("Open MegaMap", pinned: false)
                }
                .padding(5)
                .frame(width: 300)
                .background(ExplainerPalette.paper, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.black.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                .padding(.trailing, 70)
                .padding(.top, 3)
            }
        }
    }

    private func menuRow(_ title: String, pinned: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.caption2)
                .foregroundStyle(pinned ? ExplainerPalette.tiled : ExplainerPalette.titleText.opacity(0.6))
            Text(title)
                .font(.caption)
                .foregroundStyle(Color(red: 0.12, green: 0.15, blue: 0.2))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(pinned ? ExplainerPalette.tiled.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct LayoutOutcomeExplainerDiagram: View {
    var body: some View {
        ExplainerTwoUp {
            ExplainerDesktopStage(title: "Leave Floating", label: "Arrange Windows into a Floating Grid", windows: [
                .init(title: "A", tint: .blue, frame: CGRect(x: 0.04, y: 0.04, width: 0.44, height: 0.44), state: .floating),
                .init(title: "B", tint: .orange, frame: CGRect(x: 0.52, y: 0.04, width: 0.44, height: 0.44), state: .floating, focused: true),
                .init(title: "C", tint: .green, frame: CGRect(x: 0.04, y: 0.52, width: 0.44, height: 0.44), state: .floating),
                .init(title: "D", tint: .purple, frame: CGRect(x: 0.52, y: 0.52, width: 0.44, height: 0.44), state: .floating),
            ])
        } trailing: {
            ExplainerDesktopStage(title: "End Tiled", label: "Retile Windows into a Balanced Tiled Layout", windows: [
                .init(title: "A", tint: .blue, frame: CGRect(x: 0, y: 0, width: 0.49, height: 1), state: .tiled, focused: true),
                .init(title: "B", tint: .orange, frame: CGRect(x: 0.51, y: 0, width: 0.49, height: 0.49), state: .tiled),
                .init(title: "C", tint: .green, frame: CGRect(x: 0.51, y: 0.51, width: 0.49, height: 0.49), state: .tiled),
            ])
        }
    }
}
