import SwiftUI

private enum ExplainerDiagramMetrics {
    static let pairedStageMinWidth: CGFloat = 220
    static let pairedStageMaxWidth: CGFloat = 252
    static let pairedStageSpacing: CGFloat = 12
    static let stageHeight: CGFloat = 132
}

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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
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

private struct ExplainerWindowBlock: View {
    let title: String
    let color: Color
    var size: CGSize
    var focused: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(color.opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(focused ? color : color.opacity(0.55), lineWidth: focused ? 3 : 1.5)
            )
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            .frame(width: size.width, height: size.height)
    }
}

struct DesktopAutoTilingExplainerDiagram: View {
    var body: some View {
        ExplainerTwoUp {
            ExplainerStage(title: "On: windows tile") {
                HStack(spacing: 6) {
                    ExplainerWindowBlock(title: "Mail", color: .blue, size: .init(width: 58, height: 74), focused: true)
                    VStack(spacing: 6) {
                        ExplainerWindowBlock(title: "Notes", color: .orange, size: .init(width: 70, height: 34))
                        ExplainerWindowBlock(title: "Safari", color: .green, size: .init(width: 70, height: 34))
                    }
                }
            }
        } trailing: {
            ExplainerStage(title: "Off: windows float") {
                ZStack {
                    ExplainerWindowBlock(title: "Mail", color: .blue, size: .init(width: 78, height: 52))
                        .offset(x: -18, y: 10)
                    ExplainerWindowBlock(title: "Notes", color: .orange, size: .init(width: 72, height: 46), focused: true)
                        .offset(x: 10, y: -14)
                    ExplainerWindowBlock(title: "Safari", color: .green, size: .init(width: 68, height: 42))
                        .offset(x: 26, y: 18)
                }
            }
        }
    }
}

struct AppRulesExplainerDiagram: View {
    var body: some View {
        ExplainerTwoUp {
            ExplainerStage(title: "Global default") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Float by default")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ZStack(alignment: .topLeading) {
                        ExplainerWindowBlock(title: "Terminal", color: .blue, size: .init(width: 82, height: 50))
                            .offset(x: 12, y: 18)
                        ExplainerWindowBlock(title: "Notes", color: .orange, size: .init(width: 76, height: 44))
                    }
                }
            }
        } trailing: {
            ExplainerStage(title: "App rule overrides it") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Chrome: Always Tile")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ExplainerWindowBlock(title: "Chrome", color: .blue, size: .init(width: 54, height: 66), focused: true)
                        VStack(spacing: 6) {
                            ExplainerWindowBlock(title: "Slack", color: .orange, size: .init(width: 70, height: 30))
                            ExplainerWindowBlock(title: "Finder", color: .green, size: .init(width: 70, height: 30))
                        }
                    }
                }
            }
        }
    }
}

struct HoverFocusExplainerDiagram: View {
    var body: some View {
        ExplainerTwoUp {
            ExplainerStage(title: "Hover moves focus") {
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 10) {
                        ExplainerWindowBlock(title: "Mail", color: .gray, size: .init(width: 62, height: 58))
                        ExplainerWindowBlock(title: "Safari", color: .blue, size: .init(width: 72, height: 58), focused: true)
                    }
                    Image(systemName: "cursorarrow")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .offset(x: 94, y: 10)
                }
            }
        } trailing: {
            ExplainerStage(title: "Cursor follows focus") {
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 10) {
                        ExplainerWindowBlock(title: "Mail", color: .blue, size: .init(width: 72, height: 58), focused: true)
                        ExplainerWindowBlock(title: "Safari", color: .gray, size: .init(width: 62, height: 58))
                    }
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.title3)
                        .foregroundStyle(.blue)
                        .offset(x: 26, y: 10)
                }
            }
        }
    }
}

struct DesktopScrubExplainerDiagram: View {
    var body: some View {
        ExplainerTwoUp {
            ExplainerStage(title: "Hold the trigger keys") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        scrubKey("⇧")
                        scrubKey("⌃")
                        scrubKey("⌥")
                    }

                    HStack(spacing: 12) {
                        roundedDesktop("1", active: true)
                        roundedDesktop("2", active: false)
                        roundedDesktop("3", active: false)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "cursorarrow")
                            .font(.title3)
                        Text("Move the mouse left or right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } trailing: {
            ExplainerStage(title: "Let go and settle there") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        roundedDesktop("1", active: false)
                        roundedDesktop("2", active: true)
                        roundedDesktop("3", active: false)
                    }

                    ZStack {
                        Capsule()
                            .fill(Color.blue.opacity(0.14))
                            .frame(width: 130, height: 18)
                        Image(systemName: "arrow.left.and.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                    }

                    Text("When you let go of the trigger keys, macOS settles on the desktop you scrubbed to.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func scrubKey(_ symbol: String) -> some View {
        Text(symbol)
            .font(.subheadline.weight(.semibold))
            .frame(width: 34, height: 26)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
    }

    private func roundedDesktop(_ label: String, active: Bool) -> some View {
        Text("#\(label)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(active ? Color.white : Color.primary)
            .frame(width: 42, height: 28)
            .background(
                Capsule()
                    .fill(active ? Color.blue : Color.secondary.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .stroke(active ? Color.blue : Color.secondary.opacity(0.18), lineWidth: 1)
            )
    }
}

struct RightClickMenuExplainerDiagram: View {
    var body: some View {
        ExplainerStage(title: "Pin items here") {
            HStack(spacing: 14) {
                VStack(spacing: 6) {
                    Circle()
                        .fill(Color.primary.opacity(0.8))
                        .frame(width: 18, height: 18)
                    Text("Menu bar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    menuRow("Float All Windows", pinned: true)
                    menuRow("Arrange Windows into a Floating Grid", pinned: true)
                    menuRow("Open MegaMap", pinned: false)
                }
            }
        }
    }

    private func menuRow(_ title: String, pinned: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.caption2)
                .foregroundStyle(pinned ? .orange : .secondary)
            Text(title)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct LayoutOutcomeExplainerDiagram: View {
    var body: some View {
        ExplainerTwoUp {
            ExplainerStage(title: "Leave Floating") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Arrange Windows into a Floating Grid")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        VStack(spacing: 6) {
                            ExplainerWindowBlock(title: "A", color: .blue, size: .init(width: 44, height: 28))
                            ExplainerWindowBlock(title: "C", color: .green, size: .init(width: 44, height: 28))
                        }
                        VStack(spacing: 6) {
                            ExplainerWindowBlock(title: "B", color: .orange, size: .init(width: 44, height: 28), focused: true)
                            ExplainerWindowBlock(title: "D", color: .purple, size: .init(width: 44, height: 28))
                        }
                    }
                }
            }
        } trailing: {
            ExplainerStage(title: "End Tiled") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Retile Windows into a Balanced Tiled Layout")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ExplainerWindowBlock(title: "A", color: .blue, size: .init(width: 54, height: 64), focused: true)
                        VStack(spacing: 6) {
                            ExplainerWindowBlock(title: "B", color: .orange, size: .init(width: 60, height: 29))
                            ExplainerWindowBlock(title: "C", color: .green, size: .init(width: 60, height: 29))
                        }
                    }
                }
            }
        }
    }
}
