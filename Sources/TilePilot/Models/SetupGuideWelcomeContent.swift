import Foundation

/// One page of the first-launch feature tour shown before the setup checklist.
/// The tour teaches what TilePilot does and which macOS permission each
/// feature needs, before any permission can be requested.
struct SetupGuideWelcomePage: Identifiable, Equatable, Sendable {
    enum PermissionRequirement: Equatable, Sendable {
        case none
        case required(name: String)
        case optional(name: String)
    }

    struct FeatureHighlight: Identifiable, Equatable, Sendable {
        let id: String
        let symbolName: String
        let title: String
        let detail: String
    }

    let id: String
    let symbolName: String
    let title: String
    let subtitle: String
    let highlights: [FeatureHighlight]
    let permission: PermissionRequirement
    let permissionExplanation: String?
}

enum SetupGuideWelcomeContent {
    static let pages: [SetupGuideWelcomePage] = [
        SetupGuideWelcomePage(
            id: "welcome",
            symbolName: "sparkles",
            title: "Welcome to TilePilot",
            subtitle: "Tiled desktops, floating layouts, and keyboard-driven window control for your Mac, all from one menu bar app.",
            highlights: [
                .init(id: "tiling", symbolName: "square.grid.2x2", title: "Tiled desktops", detail: "Windows arrange themselves into a clean layout as you open and close them."),
                .init(id: "templates", symbolName: "rectangle.3.offgrid", title: "Floating templates", detail: "Save favorite window arrangements and reapply them with one action."),
                .init(id: "shortcuts", symbolName: "keyboard", title: "Global shortcuts", detail: "Jump between desktops, move windows, and change focus without the mouse."),
                .init(id: "maps", symbolName: "map", title: "Desktop maps", detail: "See every desktop and window at a glance, and jump straight to any of them."),
            ],
            permission: .none,
            permissionExplanation: "The next screens show what each feature does and which macOS permission it uses. TilePilot requests nothing until you click a Start or Enable button yourself."
        ),
        SetupGuideWelcomePage(
            id: "window-control",
            symbolName: "macwindow",
            title: "Window Control",
            subtitle: "TilePilot bundles two small helpers that run under your user account: yabai arranges windows and desktops, skhd listens for your keyboard shortcuts.",
            highlights: [
                .init(id: "auto-tiling", symbolName: "square.grid.2x2", title: "Automatic tiling", detail: "Pick which desktops tile automatically and which stay free-form."),
                .init(id: "behaviors", symbolName: "hand.raised.square", title: "Per-app behaviors", detail: "Keep chosen apps floating so dialogs and utilities are never squeezed into the grid."),
                .init(id: "worksets", symbolName: "square.stack.3d.up", title: "Work Sets", detail: "Group the exact windows for a task and bring them back in order."),
                .init(id: "local", symbolName: "lock.shield", title: "Runs locally", detail: "Both helpers are installed inside your user account. Nothing phones home."),
            ],
            permission: .required(name: "Accessibility access for yabai and skhd"),
            permissionExplanation: "When you click Start Window Control in the next part, macOS shows an Accessibility prompt for each helper. Approving the exact entries named yabai and skhd is what lets them see and move windows. TilePilot never starts them before you do."
        ),
        SetupGuideWelcomePage(
            id: "shortcuts",
            symbolName: "keyboard",
            title: "Keyboard Shortcuts",
            subtitle: "Drive desktops and windows entirely from the keyboard. Every shortcut is visible and re-recordable in Actions & Shortcuts.",
            highlights: [
                .init(id: "jump", symbolName: "arrow.right.circle", title: "Jump to any desktop", detail: "Option plus a number switches desktops instantly."),
                .init(id: "move", symbolName: "arrow.up.left.and.arrow.down.right", title: "Move and resize", detail: "Send the focused window to another tile, desktop, or display."),
                .init(id: "layout", symbolName: "circle.grid.2x2", title: "Shape the layout", detail: "Rotate, balance, and swap tiles without touching the mouse."),
                .init(id: "custom", symbolName: "command", title: "Yours to change", detail: "Record different key combos any time; TilePilot keeps the config file tidy."),
            ],
            permission: .none,
            permissionExplanation: "Shortcuts use the same skhd helper from the previous screen. No additional permission is needed."
        ),
        SetupGuideWelcomePage(
            id: "maps",
            symbolName: "map",
            title: "Mini-map & MegaMap",
            subtitle: "A live overview of your desktops. Click a window to jump to it, even when it is buried behind everything else.",
            highlights: [
                .init(id: "minimap", symbolName: "map", title: "Mini-map", detail: "The Overview tab shows each desktop as a wireframe with app icons."),
                .init(id: "megamap", symbolName: "photo", title: "MegaMap", detail: "A full-screen map with real screenshots of every desktop."),
                .init(id: "find", symbolName: "eye", title: "Find hidden windows", detail: "Spot a window under a pile and bring it to the front with one click."),
                .init(id: "on-demand", symbolName: "camera", title: "Captures on demand", detail: "Screenshots happen only when you refresh MegaMap or switch desktops with TilePilot."),
            ],
            permission: .optional(name: "Screen Recording for MegaMap screenshots"),
            permissionExplanation: "Only needed if you want real screenshot thumbnails in MegaMap. Skip it and MegaMap shows wireframes instead. macOS asks the first time you use MegaMap capture, and screenshots never leave memory."
        ),
        SetupGuideWelcomePage(
            id: "finish",
            symbolName: "checkmark.seal",
            title: "A Few Quick Checks",
            subtitle: "Next is a short checklist that starts window control and confirms this Mac is ready. The required part takes under a minute.",
            highlights: [
                .init(id: "login", symbolName: "power", title: "Start at login", detail: "Recommended so tiling is ready right after you sign in."),
                .init(id: "mission-control", symbolName: "rectangle.on.rectangle", title: "Mission Control review", detail: "Optional settings check that makes desktop switching more predictable."),
                .init(id: "return", symbolName: "questionmark.circle", title: "Come back anytime", detail: "Reopen Guided Setup from the menu bar or the System tab whenever you like."),
            ],
            permission: .none,
            permissionExplanation: nil
        ),
    ]

    static func page(at index: Int) -> SetupGuideWelcomePage? {
        guard pages.indices.contains(index) else { return nil }
        return pages[index]
    }

    static func isLastPage(_ index: Int) -> Bool {
        index >= pages.count - 1
    }
}
