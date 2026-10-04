import SwiftUI

struct HowItWorksDashboardView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    introCard
                    windowBehaviorSection
                    shortcutsSection
                    recentWindowPickerSection
                    workSetsSection
                }
                .padding()
            }
            .navigationTitle("How It Works")
        }
    }

    private var introCard: some View {
        GroupBox {
            Text("Use this tab for quick visual explanations. The settings tabs stay focused on changing behavior.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Overview", systemImage: "lightbulb")
        }
    }

    private var windowBehaviorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Window Behavior")
            conceptCard(
                title: "Desktop Auto-Tiling",
                summary: "Each desktop can either keep windows tiled or leave them floating."
            ) {
                DesktopAutoTilingExplainerDiagram()
            }
            conceptCard(
                title: "App Rules",
                summary: "App rules override the global default for specific apps."
            ) {
                AppRulesExplainerDiagram()
            }
            conceptCard(
                title: "Focus and Cursor",
                summary: "Hover Focus changes focus on pointer movement. Cursor Follows Focus moves the pointer to the focused window."
            ) {
                HoverFocusExplainerDiagram()
            }
            conceptCard(
                title: "Desktop Scrub",
                summary: "Hold the trigger keys, move the mouse left or right, then let go and macOS settles on that desktop."
            ) {
                DesktopScrubExplainerDiagram()
            }
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Actions and Shortcuts")
            conceptCard(
                title: "Right-Click Menu",
                summary: "Pin high-frequency actions so they appear when you right-click the TilePilot menu bar icon."
            ) {
                RightClickMenuExplainerDiagram()
            }
            conceptCard(
                title: "Layout Outcomes",
                summary: "Some layout actions leave windows floating. Others finish with windows tiled. The name should tell you the result before you run it."
            ) {
                LayoutOutcomeExplainerDiagram()
            }
            conceptCard(
                title: "Templates vs Work Sets",
                summary: "Templates save layout slots. Work Sets save which windows belong together on one desktop, and can now own stack order, tiled layout, or a linked template."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Templates: saved floating layout geometry", systemImage: "rectangle.3.offgrid")
                    Label("Work Sets: saved same-desktop membership, order, optional backdrop, and per-set layout mode", systemImage: "square.stack.3d.up")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var recentWindowPickerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Pick Windows to Tile")
            conceptCard(
                title: "What It Is For",
                summary: "Use this when you want to tile only a small recent set instead of the whole desktop."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("The list is front-to-back window order on the current desktop", systemImage: "square.stack.3d.up")
                    Label("The picker starts with your last selected count; first use starts at 4", systemImage: "number")
                    Label("Click rows to include or exclude windows", systemImage: "checkmark.circle")
                    Label("Window titles are shown first when they add useful context", systemImage: "textformat")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            conceptCard(
                title: "Preview and Order",
                summary: "The preview shows the exact floating grid result before you apply it."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Numbers in the list and preview are placement order", systemImage: "list.number")
                    Label("Drag rows or preview tiles to change which window goes into each spot", systemImage: "arrow.up.arrow.down.square")
                    Label("Spare grid cells are filled by stretching nearby windows vertically", systemImage: "arrow.down.to.line.compact")
                    Label("Floating Grid and Template modes both match the preview", systemImage: "rectangle.grid.2x2")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            conceptCard(
                title: "Exact Layout Modes",
                summary: "The picker only shows modes where the preview is the result."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Floating Grid keeps windows floating and places them into exact slots", systemImage: "rectangle.3.group")
                    Label("Template places selected windows into compatible saved template slots", systemImage: "rectangle.on.rectangle")
                    Label("True yabai tiling stays in desktop tiling actions and Work Set Tile mode", systemImage: "rectangle.split.3x1")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var workSetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Work Sets")
            conceptCard(
                title: "What a Work Set Saves",
                summary: "A Work Set is a same-desktop task group. It saves which windows belong together, which one should come to the front first, and how that set should lay out when activated."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Scope picker: choose the visible desktop on the screen you want to manage", systemImage: "display")
                    Label("Board lanes: each lane is one Work Set for that desktop", systemImage: "square.stack.3d.up")
                    Label("Live Layout: shows the current wireframe of the matched windows", systemImage: "rectangle.3.group")
                    Label("Layout mode: Floating, Tile, or Template", systemImage: "slider.horizontal.3")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            conceptCard(
                title: "How to Build One",
                summary: "Start from the current desktop pile, then split it into task groups."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Import Visible Windows to create one front-to-back starting pile", systemImage: "square.and.arrow.down")
                    Label("Drag windows between lanes to move them into another Work Set", systemImage: "arrow.left.and.right.square")
                    Label("Use Also Add on a row to keep the same window in more than one Work Set", systemImage: "plus.square.on.square")
                    Label("Use New Work Set to spin off another lane", systemImage: "plus.rectangle.on.rectangle")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            conceptCard(
                title: "What Activation Does",
                summary: "Activating a Work Set reapplies that task once, then stops. TilePilot does not keep rearranging the desktop afterward."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Floating: brings that Work Set forward without changing the current window positions", systemImage: "square.stack.3d.up")
                    Label("Tile: tiles that Work Set when activated and leaves the result in place", systemImage: "rectangle.split.3x1")
                    Label("Template: places the matched windows into the linked template slots", systemImage: "rectangle.3.offgrid")
                    Label("Backdrop can place a solid color behind that Work Set", systemImage: "rectangle.inset.filled")
                    Label("Cycle Work Sets switches between the saved sets on the current desktop", systemImage: "arrow.triangle.2.circlepath")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    private func conceptCard<Content: View>(
        title: String,
        summary: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
    }
}
