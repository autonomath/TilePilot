import SwiftUI

/// What one part of TilePilot does and why, shown from the ⓘ button beside the section it
/// explains. Settings copy stays short and outcome-based; the teaching lives here, one click away
/// from the control it describes.
enum ContextHelpTopic: String, CaseIterable, Identifiable {
    case desktopAutoTiling
    case appRules
    case mouseDragging
    case focusAndCursor
    case desktopScrub
    case workArea
    case workAreaMenuBar
    case workAreaContainment
    case rightClickMenu
    case layoutOutcomes
    case templates
    case workSets
    case windowPicker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .desktopAutoTiling: return "Desktop Auto-Tiling"
        case .appRules: return "App Rules"
        case .mouseDragging: return "Mouse Dragging"
        case .focusAndCursor: return "Focus and Cursor"
        case .desktopScrub: return "Desktop Scrub"
        case .workArea: return "Work Area"
        case .workAreaMenuBar: return "Work Area Menu Bar"
        case .workAreaContainment: return "Keeping Windows Inside"
        case .rightClickMenu: return "Right-Click Menu"
        case .layoutOutcomes: return "Floating or Tiled Results"
        case .templates: return "Templates"
        case .workSets: return "Work Sets"
        case .windowPicker: return "Pick Windows to Tile"
        }
    }

    var summary: String {
        switch self {
        case .desktopAutoTiling:
            return "Each desktop either tiles its windows or leaves them floating. The desktop decides first: with tiling Off, every window there floats. With tiling On, app rules pick the apps that stay out."
        case .appRules:
            return "Apps without a rule follow the default for new windows. A rule changes that for one app, on every desktop where tiling is On."
        case .mouseDragging:
            return "Hold the modifier key and drag anywhere inside a window, so you don't have to aim for the title bar or an edge."
        case .focusAndCursor:
            return "Hover focus moves focus to the window under the pointer. Cursor follows focus works the other way: when focus changes from the keyboard, the pointer jumps to the new window."
        case .desktopScrub:
            return "Hold the trigger keys and move the mouse left or right to slide through your desktops. Let go, and macOS settles on the desktop you stopped at."
        case .workArea:
            return "A smaller rectangle on one display. TilePilot keeps windows inside it, so a very large screen works like a normal one. The display resolution doesn't change."
        case .workAreaMenuBar:
            return "A copy of the menu bar at the top of the Work Area, so menus and icons sit right above your windows. With it off, the Work Area works the same with the real menu bar."
        case .workAreaContainment:
            return "Some windows have a minimum size or refuse to move. TilePilot tries twice, lists the window under Exceptions, and tries again every 30 seconds."
        case .rightClickMenu:
            return "Pinned actions appear when you right-click the TilePilot icon in the menu bar, in the order shown here. Right-clicking a window badge shows them too."
        case .layoutOutcomes:
            return "Each layout action's name says how it ends. Some arrange windows and leave them floating; others end with the desktop tiled."
        case .templates:
            return "A template saves where windows go: floating slots drawn for one display shape. Applying it fills the slots with windows from the current desktop and leaves them floating."
        case .workSets:
            return "A Work Set is a group of windows on one desktop that belong to the same task. Activating it brings those windows forward and lays them out once; TilePilot doesn't keep rearranging them afterward."
        case .windowPicker:
            return "Arrange a few recent windows instead of the whole desktop. The preview is the exact result."
        }
    }

    var points: [ContextHelpPoint] {
        switch self {
        case .desktopAutoTiling:
            return [
                .init("The mini-map on Overview has the same switch on every desktop", systemImage: "rectangle.3.group"),
            ]
        case .appRules:
            return [
                .init("Never Auto-Tile keeps an app floating, even on a tiled desktop", systemImage: "rectangle.on.rectangle"),
                .init("Always Tile tiles an app even when new windows float by default", systemImage: "rectangle.split.3x1"),
                .init("Keep on Top raises the app's floating windows above the others", systemImage: "square.stack.3d.up"),
                .init("Switching a window to floating brings it to the front", systemImage: "arrow.up.forward.square"),
                .init("Older rules in yabairc, outside TilePilot's section, can also float or tile apps", systemImage: "doc.text"),
            ]
        case .mouseDragging:
            return [
                .init("Each mouse button gets its own job: move or resize", systemImage: "computermouse"),
                .init("Drop a tiled window near the center of another to swap or stack them", systemImage: "arrow.left.arrow.right"),
                .init("Drop actions only apply to tiled windows; floating windows just move", systemImage: "macwindow"),
            ]
        case .focusAndCursor:
            return [
                .init("Auto Focus focuses without raising; Auto Raise also brings the window to the front", systemImage: "cursorarrow.rays"),
                .init("Hover focus can get in the way when you reach for the menu bar", systemImage: "menubar.rectangle"),
            ]
        case .desktopScrub:
            return [
                .init("Pick at least two modifier keys; an extra letter key makes accidental scrubs rare", systemImage: "keyboard"),
                .init("Sensitivity sets how far each mouse movement travels", systemImage: "speedometer"),
            ]
        case .workArea:
            return [
                .init("Tiled windows always stay inside it", systemImage: "rectangle.split.3x1"),
                .init("Floating windows dragged outside move back in when you let go", systemImage: "arrow.down.right.and.arrow.up.left"),
                .init("Double-clicking a title bar fills the Work Area", systemImage: "macwindow"),
                .init("Floating Grid, Templates, Work Sets, and Fill Work Area place windows inside it", systemImage: "rectangle.3.offgrid"),
                .init("Screen Edge Padding still applies inside it", systemImage: "square.dashed"),
                .init("The real menu bar, Dock, notifications, desktop icons, and the pointer still use the whole display", systemImage: "display"),
            ]
        case .workAreaMenuBar:
            return [
                .init("Menus open right under it, and the app you're using stays in front", systemImage: "menubar.rectangle"),
                .init("Clicking an icon clicks the real one; panels such as Wi-Fi open at the real menu bar", systemImage: "cursorarrow.click"),
                .init("Icons from other displays appear once each, in a row that stays put", systemImage: "rectangle.split.2x1"),
                .init("Matching the real icons copies their pixels with Screen Recording, in memory only; without it, TilePilot draws symbols and app icons", systemImage: "photo"),
            ]
        case .workAreaContainment:
            return [
                .init("Allow Outside frees one window until TilePilot restarts", systemImage: "rectangle.portrait.and.arrow.right"),
                .init("Apps Allowed Outside frees every window from an app", systemImage: "app.badge.checkmark"),
                .init("Undo Last Fit puts the windows TilePilot just moved back where they were", systemImage: "arrow.uturn.backward"),
                .init("Dialogs, sheets, and tool palettes are never moved", systemImage: "macwindow.on.rectangle"),
            ]
        case .rightClickMenu:
            return []
        case .layoutOutcomes:
            return [
                .init("Float and Floating Grid actions leave windows floating where they land", systemImage: "rectangle.3.group"),
                .init("Tile and Retile actions turn tiling on for the desktop", systemImage: "rectangle.split.3x1"),
                .init("Never Auto-Tile apps stay floating either way", systemImage: "rectangle.on.rectangle"),
            ]
        case .templates:
            return [
                .init("Slots with app rules fill first; Any App slots take the focused window, then the rest in desktop order", systemImage: "list.number"),
                .init("Slots can overlap; the layer order decides which window ends up in front", systemImage: "square.3.stack.3d"),
                .init("When the display shape is close, the template fits itself to it", systemImage: "arrow.down.right.and.arrow.up.left"),
                .init("Work Sets save which windows belong together; a Work Set can use a template as its layout", systemImage: "square.stack.3d.up"),
            ]
        case .workSets:
            return [
                .init("Import Visible Windows starts one pile from the desktop, front to back", systemImage: "square.and.arrow.down"),
                .init("Drag windows between lanes to split the pile into sets; Also Add puts a window in more than one", systemImage: "arrow.left.and.right.square"),
                .init("Floating brings the set forward as it is; Tile tiles it; Template places it into a template's slots", systemImage: "slider.horizontal.3"),
                .init("A backdrop can cover everything behind the set", systemImage: "rectangle.inset.filled"),
                .init("Cycle Work Sets switches between the sets on the current desktop", systemImage: "arrow.triangle.2.circlepath"),
            ]
        case .windowPicker:
            return [
                .init("The list is front-to-back order on this desktop; click rows to include or skip them", systemImage: "checkmark.circle"),
                .init("Numbers are placement order; drag rows or preview tiles to change it", systemImage: "list.number"),
                .init("Floating Grid places windows into exact slots and leaves them floating", systemImage: "rectangle.grid.2x2"),
                .init("Template uses the slots of a saved template that fits this display", systemImage: "rectangle.3.offgrid"),
                .init("Spare grid cells are filled by stretching nearby windows down", systemImage: "arrow.down.to.line.compact"),
                .init("The picker starts with as many windows as you picked last time", systemImage: "number"),
            ]
        }
    }

    var hasDiagram: Bool {
        switch self {
        case .desktopAutoTiling, .appRules, .focusAndCursor, .desktopScrub, .rightClickMenu, .layoutOutcomes:
            return true
        case .mouseDragging, .workArea, .workAreaMenuBar, .workAreaContainment, .templates, .workSets, .windowPicker:
            return false
        }
    }
}

struct ContextHelpPoint: Hashable {
    let text: String
    let systemImage: String

    init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }
}

/// The ⓘ beside a section title. Clicking it opens the topic's explanation, with its diagram when
/// it has one.
struct ContextHelpButton: View {
    let topic: ContextHelpTopic
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: isPresented ? "info.circle.fill" : "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isPresented ? Color.accentColor : Color.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("How \(topic.title) works")
        .accessibilityLabel("About \(topic.title)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ContextHelpCard(topic: topic)
        }
    }
}

/// A section title followed by its ⓘ, for GroupBox labels and list section headers.
struct HelpSectionLabel: View {
    let title: String
    let systemImage: String
    let topic: ContextHelpTopic

    var body: some View {
        HStack(spacing: 5) {
            Label(title, systemImage: systemImage)
            ContextHelpButton(topic: topic)
        }
    }
}

struct ContextHelpCard: View {
    let topic: ContextHelpTopic

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(topic.title)
                .font(.headline)

            Text(topic.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if topic.hasDiagram {
                diagram
            }

            if !topic.points.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(topic.points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: point.systemImage)
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(point.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: topic.hasDiagram ? 680 : 420, alignment: .leading)
    }

    @ViewBuilder
    private var diagram: some View {
        switch topic {
        case .desktopAutoTiling:
            DesktopAutoTilingExplainerDiagram()
        case .appRules:
            AppRulesExplainerDiagram()
        case .focusAndCursor:
            HoverFocusExplainerDiagram()
        case .desktopScrub:
            DesktopScrubExplainerDiagram()
        case .rightClickMenu:
            RightClickMenuExplainerDiagram()
        case .layoutOutcomes:
            LayoutOutcomeExplainerDiagram()
        case .mouseDragging, .workArea, .workAreaMenuBar, .workAreaContainment, .templates, .workSets, .windowPicker:
            EmptyView()
        }
    }
}
