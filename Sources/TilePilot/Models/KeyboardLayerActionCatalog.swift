import CoreGraphics
import Foundation

/// The key window's sidebar, in order.
enum KeyboardLayerActionCategory: String, CaseIterable, Identifiable, Sendable {
    case windows, desktops, layouts, apps, macOS, open, keysAndText, automation, tilePilot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windows: return "Windows"
        case .desktops: return "Desktops"
        case .layouts: return "Layouts"
        case .apps: return "Apps"
        case .macOS: return "macOS"
        case .open: return "Open"
        case .keysAndText: return "Keys & Text"
        case .automation: return "Automation"
        case .tilePilot: return "TilePilot"
        }
    }

    var systemImage: String {
        switch self {
        case .windows: return "macwindow"
        case .desktops: return "rectangle.3.group"
        case .layouts: return "square.grid.3x3"
        case .apps: return "app.badge"
        case .macOS: return "desktopcomputer"
        case .open: return "link"
        case .keysAndText: return "keyboard"
        case .automation: return "gearshape.2"
        case .tilePilot: return "rectangle.split.3x3"
        }
    }

    /// The sections inside the category, in order.
    var sections: [String] {
        switch self {
        case .windows: return ["Focus", "Snap", "Arrange", "Resize", "State", "Move To", "More"]
        case .desktops: return ["Go To"]
        case .layouts: return ["Tiling", "Templates", "Work Sets"]
        case .apps: return ["Front App", "Running", "All Apps"]
        case .macOS: return ["Overview", "Input", "Session", "Screenshots", "Media", "Sound", "Display"]
        case .open: return ["Open"]
        case .keysAndText: return ["Keys & Text"]
        case .automation: return ["Apple Shortcuts", "Commands", "Your skhd Shortcuts"]
        case .tilePilot: return ["TilePilot"]
        }
    }
}

/// An action that needs input in the key window's settings area.
enum KeyboardLayerActionSetting: Hashable, Sendable {
    case url, file, folder, text, command, shortcut

    var title: String {
        switch self {
        case .url: return "Open URL…"
        case .file: return "Open File…"
        case .folder: return "Open Folder…"
        case .text: return "Type Text…"
        case .command: return "Shell Command…"
        case .shortcut: return "Send Shortcut…"
        }
    }

    var systemImage: String {
        switch self {
        case .url: return "link"
        case .file: return "doc"
        case .folder: return "folder"
        case .text: return "text.cursor"
        case .command: return "terminal"
        case .shortcut: return "command"
        }
    }

    /// The setting that edits this action, if it has one.
    init?(_ action: KeyboardLayerAction?) {
        switch action {
        case .typeText?: self = .text
        case .openURL?: self = .url
        case .openPath(let path)?:
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &isDirectory)
            self = exists && isDirectory.boolValue ? .folder : .file
        case .runCommand(_, nil)?: self = .command
        case .sendShortcut?: self = .shortcut
        default: return nil
        }
    }
}

/// What's typed in the key window's settings area. It becomes the key's action on Done, on
/// close, or when another action is chosen.
struct KeyboardLayerEditorDraft: Equatable, Sendable {
    var setting: KeyboardLayerActionSetting
    var text = ""

    /// The action to save. Empty text saves no action.
    var action: KeyboardLayerAction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch setting {
        case .text: return .typeText(text)
        case .command: return .runCommand(command: text, title: nil)
        case .url: return .openURL(trimmed)
        case .file, .folder: return .openPath(trimmed)
        case .shortcut: return nil
        }
    }
}

extension KeyboardLayerEditorDraft {
    /// Starts from the key's action when the settings area edits it as text.
    init?(_ action: KeyboardLayerAction?) {
        switch action {
        case .typeText(let text)?: self.init(setting: .text, text: text)
        case .openURL(let address)?: self.init(setting: .url, text: address)
        case .openPath(let path)?: self.init(setting: KeyboardLayerActionSetting(action) ?? .file, text: path)
        case .runCommand(let command, nil)?: self.init(setting: .command, text: command)
        default: return nil
        }
    }
}

enum KeyboardLayerRequirement: Equatable, Sendable {
    case none, yabai, scriptingAddition
}

enum KeyboardLayerFrontAppCommand: Equatable, Sendable {
    case hide, hideOthers, quit
}

/// What a built-in action does.
enum KeyboardLayerBuiltInWork: Equatable, Sendable {
    /// yabai commands, run in order; the first failure stops the rest.
    case yabai([[String]])
    /// Floats the window if it's tiled, then places it in this part of the Work Area (normalized,
    /// top-left origin). Nil keeps its size and centers it.
    case snap(CGRect?)
    case goToDesktop(Int)
    /// yabai's space selector (a number, next, or prev); the desktop follows the window.
    case moveToDesktop(String)
    /// Keystrokes, 200 ms apart.
    case keys([KeyboardLayerChord])
    /// A media, sound, or brightness key (NX_KEYTYPE_*).
    case systemKey(Int32)
    /// A Mission Control view through yabai, or the Mission Control app with this argument when
    /// yabai can't run it.
    case overview(yabai: [String], missionControlArgument: String?)
    case openSystemApp(path: String)
    case process(path: String, arguments: [String])
    case frontApp(KeyboardLayerFrontAppCommand)
}

struct KeyboardLayerBuiltIn: Identifiable, Sendable {
    /// Saved with the binding; never reuse one for a different action.
    let id: String
    let category: KeyboardLayerActionCategory
    let section: String
    let title: String
    let systemImage: String
    var keywords: [String] = []
    var requirement: KeyboardLayerRequirement = .none
    let work: KeyboardLayerBuiltInWork
}

/// One row of the key window's list.
struct KeyboardLayerPickerItem: Identifiable, Equatable {
    enum Icon: Equatable {
        case symbol(String)
        case app(path: String)
    }

    enum Choice: Equatable {
        case action(KeyboardLayerAction)
        case setting(KeyboardLayerActionSetting)
        case chooseApp
    }

    let id: String
    let category: KeyboardLayerActionCategory
    let section: String
    let title: String
    let icon: Icon
    var note: String?
    var keywords: [String] = []
    let choice: Choice

    /// Whether this row is the key's current action.
    func matches(_ action: KeyboardLayerAction?) -> Bool {
        guard let action else { return false }
        switch (choice, action) {
        case (.action(.feature(let id, _)), .feature(let current, _)),
             (.action(.builtIn(let id, _)), .builtIn(let current, _)):
            return id == current
        case (.action(.openApp(let app)), .openApp(let current)):
            return app.bundleID.map { $0 == current.bundleID } ?? (app.path == current.path)
        case (.action(.runAppleShortcut(let name)), .runAppleShortcut(let current)):
            return name == current
        case (.action(.runCommand(let command, _)), .runCommand(let current, let title)):
            return title != nil && command == current
        case (.setting(let setting), _):
            return KeyboardLayerActionSetting(action) == setting
        default:
            return false
        }
    }
}

/// Everything a layer key can do, grouped for the key window.
enum KeyboardLayerActionCatalog {
    struct Feature: Sendable {
        let id: String
        let title: String
        let group: UnifiedControlGroup
    }

    struct SkhdShortcut: Sendable {
        let title: String
        let combo: String
        let command: String
    }

    static let builtIns: [KeyboardLayerBuiltIn] = windowBuiltIns + desktopBuiltIns + layoutBuiltIns + appBuiltIns + macOSBuiltIns

    private static let builtInsByID = Dictionary(builtIns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    static func builtIn(id: String) -> KeyboardLayerBuiltIn? {
        builtInsByID[id]
    }

    /// Every row, in sidebar and section order. `unmetNote` explains a requirement that isn't
    /// met right now.
    static func items(
        features: [Feature],
        runningApps: [KeyboardLayerApp],
        installedApps: [KeyboardLayerApp],
        appleShortcuts: [String],
        skhdShortcuts: [SkhdShortcut],
        appExists: (String) -> Bool,
        unmetNote: (KeyboardLayerRequirement) -> String?
    ) -> [KeyboardLayerPickerItem] {
        var items: [KeyboardLayerPickerItem] = features.compactMap { feature in
            guard let place = placement(featureID: feature.id, group: feature.group) else { return nil }
            return KeyboardLayerPickerItem(
                id: "feature.\(feature.id)", category: place.category, section: place.section, title: feature.title,
                icon: .symbol(feature.group.systemImage), keywords: [feature.group.title],
                choice: .action(.feature(id: feature.id, title: feature.title))
            )
        }
        for builtIn in builtIns {
            if case .openSystemApp(let path) = builtIn.work, !appExists(path) { continue }
            items.append(KeyboardLayerPickerItem(
                id: builtIn.id, category: builtIn.category, section: builtIn.section, title: builtIn.title,
                icon: .symbol(builtIn.systemImage), note: unmetNote(builtIn.requirement), keywords: builtIn.keywords,
                choice: .action(.builtIn(id: builtIn.id, title: builtIn.title))
            ))
        }
        // A running app is listed once, under Running.
        let running = Set(runningApps.map { $0.bundleID ?? $0.path })
        let notRunning = installedApps.filter { !running.contains($0.bundleID ?? $0.path) }
        for (section, apps) in [("Running", runningApps), ("All Apps", notRunning)] {
            for app in apps {
                items.append(KeyboardLayerPickerItem(
                    id: "\(section).\(app.bundleID ?? app.path)", category: .apps, section: section, title: app.name,
                    icon: .app(path: app.path), choice: .action(.openApp(app))
                ))
            }
        }
        items.append(KeyboardLayerPickerItem(
            id: "choose-app", category: .apps, section: "All Apps", title: "Choose Other App…",
            icon: .symbol("ellipsis.circle"), keywords: ["open"], choice: .chooseApp
        ))
        let settings: [(KeyboardLayerActionCategory, String, KeyboardLayerActionSetting, [String])] = [
            (.open, "Open", .url, ["website", "address", "link"]),
            (.open, "Open", .file, ["document"]),
            (.open, "Open", .folder, ["directory", "finder"]),
            (.keysAndText, "Keys & Text", .shortcut, ["keystroke", "key", "hotkey"]),
            (.keysAndText, "Keys & Text", .text, ["paste", "snippet", "type"]),
            (.automation, "Commands", .command, ["script", "zsh", "bash", "run"]),
        ]
        for (category, section, setting, keywords) in settings {
            items.append(KeyboardLayerPickerItem(
                id: "setting.\(setting.title)", category: category, section: section, title: setting.title,
                icon: .symbol(setting.systemImage), keywords: keywords, choice: .setting(setting)
            ))
        }
        for name in appleShortcuts {
            items.append(KeyboardLayerPickerItem(
                id: "apple-shortcut.\(name)", category: .automation, section: "Apple Shortcuts", title: "Run “\(name)”",
                icon: .symbol("bolt.circle"), keywords: ["shortcuts", name], choice: .action(.runAppleShortcut(name: name))
            ))
        }
        for shortcut in skhdShortcuts {
            items.append(KeyboardLayerPickerItem(
                id: "skhd.\(shortcut.combo)\n\(shortcut.command)", category: .automation, section: "Your skhd Shortcuts",
                title: shortcut.title, icon: .symbol("keyboard"), note: shortcut.combo,
                keywords: ["skhd", shortcut.combo, shortcut.command],
                choice: .action(.runCommand(command: shortcut.command, title: shortcut.title))
            ))
        }

        // skhdrc can list the same line twice.
        var seen: Set<String> = []
        items = items.filter { seen.insert($0.id).inserted }
        let categoryRank = Dictionary(uniqueKeysWithValues: KeyboardLayerActionCategory.allCases.enumerated().map { ($1, $0) })
        return items.enumerated().sorted { lhs, rhs in
            let left = (categoryRank[lhs.element.category] ?? 0, lhs.element.category.sections.firstIndex(of: lhs.element.section) ?? .max, lhs.offset)
            let right = (categoryRank[rhs.element.category] ?? 0, rhs.element.category.sections.firstIndex(of: rhs.element.section) ?? .max, rhs.offset)
            return left < right
        }.map(\.element)
    }

    /// Rows whose title, section, category, note, or keywords contain every word of the query.
    static func search(_ items: [KeyboardLayerPickerItem], query: String) -> [KeyboardLayerPickerItem] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let text = ([item.title, item.section, item.category.title, item.note ?? ""] + item.keywords)
                .joined(separator: " ")
                .lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// Where a TilePilot feature sits in the key window. Experimental features stay out.
    static func placement(featureID: String, group: UnifiedControlGroup) -> (category: KeyboardLayerActionCategory, section: String)? {
        switch featureID {
        case "action.focus-left", "action.focus-right", "action.focus-up", "action.focus-down":
            return (.windows, "Focus")
        case "screen.fill-work-area":
            return (.windows, "Snap")
        case "action.toggle-float":
            return (.windows, "State")
        case "app.keep-on-top-when-floating", "app.never-auto-tile":
            return (.apps, "Front App")
        default:
            break
        }
        switch group {
        case .tilingLayout: return (.layouts, "Tiling")
        case .templates: return (.layouts, "Templates")
        case .workSets: return (.layouts, "Work Sets")
        case .focus, .windowPlacement, .windowSize: return (.windows, "More")
        case .experimental: return nil
        case .desktops, .helpersScripts, .apps, .displays, .automation, .other: return (.tilePilot, "TilePilot")
        }
    }

    /// Adds https:// to an address typed without a scheme, such as example.com.
    static func normalizedURL(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") || trimmed.lowercased().hasPrefix("mailto:") { return trimmed }
        return "https://" + trimmed
    }

    /// The first line of a text or command, shortened for a title. An ellipsis means more follows.
    static func preview(_ text: String, limit: Int = 30) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return "" }
        if first.count > limit { return String(first.prefix(limit - 1)) + "…" }
        return lines.count > 1 ? first + "…" : first
    }

    /// The sidebar category that holds a key's action, so the key window opens on it.
    static func category(for action: KeyboardLayerAction?, in items: [KeyboardLayerPickerItem]) -> KeyboardLayerActionCategory {
        switch action {
        case .none: return .windows
        case .feature?: return items.first { $0.matches(action) }?.category ?? .tilePilot
        case .builtIn(let id, _)?: return builtIn(id: id)?.category ?? .windows
        case .openApp?: return .apps
        case .sendShortcut?, .typeText?: return .keysAndText
        case .openURL?, .openPath?: return .open
        case .runAppleShortcut?, .runCommand?: return .automation
        }
    }

    // MARK: - Built-ins

    private static let directions: [(name: String, yabai: String)] = [
        ("Left", "west"), ("Right", "east"), ("Up", "north"), ("Down", "south"),
    ]

    private static func keys(_ keyCode: UInt16, _ modifiers: KeyboardLayerModifiers) -> KeyboardLayerChord {
        KeyboardLayerChord(keyCode: keyCode, modifiers: modifiers)
    }

    private static func window(
        _ id: String, _ section: String, _ title: String, _ symbol: String,
        _ keywords: [String], _ work: KeyboardLayerBuiltInWork, requirement: KeyboardLayerRequirement = .yabai
    ) -> KeyboardLayerBuiltIn {
        KeyboardLayerBuiltIn(
            id: "window.\(id)", category: .windows, section: section, title: title, systemImage: symbol,
            keywords: keywords, requirement: requirement, work: work
        )
    }

    private static let windowBuiltIns: [KeyboardLayerBuiltIn] = {
        let third = 1.0 / 3
        let slots: [(id: String, title: String, symbol: String, slot: CGRect?)] = [
            ("left-half", "Snap Left Half", "rectangle.lefthalf.filled", CGRect(x: 0, y: 0, width: 0.5, height: 1)),
            ("right-half", "Snap Right Half", "rectangle.righthalf.filled", CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
            ("top-half", "Snap Top Half", "rectangle.tophalf.filled", CGRect(x: 0, y: 0, width: 1, height: 0.5)),
            ("bottom-half", "Snap Bottom Half", "rectangle.bottomhalf.filled", CGRect(x: 0, y: 0.5, width: 1, height: 0.5)),
            ("left-third", "Snap Left Third", "rectangle.split.3x1", CGRect(x: 0, y: 0, width: third, height: 1)),
            ("center-third", "Snap Center Third", "rectangle.split.3x1", CGRect(x: third, y: 0, width: third, height: 1)),
            ("right-third", "Snap Right Third", "rectangle.split.3x1", CGRect(x: 2 * third, y: 0, width: third, height: 1)),
            ("left-two-thirds", "Snap Left Two Thirds", "rectangle.split.3x1", CGRect(x: 0, y: 0, width: 2 * third, height: 1)),
            ("right-two-thirds", "Snap Right Two Thirds", "rectangle.split.3x1", CGRect(x: third, y: 0, width: 2 * third, height: 1)),
            ("top-left", "Snap Top Left Quarter", "rectangle.split.2x2", CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
            ("top-right", "Snap Top Right Quarter", "rectangle.split.2x2", CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
            ("bottom-left", "Snap Bottom Left Quarter", "rectangle.split.2x2", CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)),
            ("bottom-right", "Snap Bottom Right Quarter", "rectangle.split.2x2", CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
            ("center", "Center Window", "rectangle.inset.filled", nil),
        ]
        var items = slots.map { window("snap.\($0.id)", "Snap", $0.title, $0.symbol, ["snap", "move", "place"], .snap($0.slot)) }
        for direction in directions {
            items.append(window("swap.\(direction.name.lowercased())", "Arrange", "Swap \(direction.name)", "arrow.left.arrow.right",
                                ["swap", "tiled"], .yabai([["-m", "window", "--swap", direction.yabai]])))
        }
        for direction in directions {
            items.append(window("warp.\(direction.name.lowercased())", "Arrange", "Warp \(direction.name)", "arrow.turn.up.right",
                                ["warp", "move", "tiled"], .yabai([["-m", "window", "--warp", direction.yabai]])))
        }
        // 80 pt per press, matching the resize step in the default skhdrc.
        let edges: [(name: String, grow: String, shrink: String)] = [
            ("Left", "left:-80:0", "left:80:0"), ("Right", "right:80:0", "right:-80:0"),
            ("Up", "top:0:-80", "top:0:80"), ("Down", "bottom:0:80", "bottom:0:-80"),
        ]
        for edge in edges {
            items.append(window("grow.\(edge.name.lowercased())", "Resize", "Grow \(edge.name)", "arrow.up.left.and.arrow.down.right",
                                ["resize", "bigger", "larger"], .yabai([["-m", "window", "--resize", edge.grow]])))
        }
        for edge in edges {
            items.append(window("shrink.\(edge.name.lowercased())", "Resize", "Shrink \(edge.name)", "arrow.down.right.and.arrow.up.left",
                                ["resize", "smaller"], .yabai([["-m", "window", "--resize", edge.shrink]])))
        }
        items += [
            window("zoom", "State", "Toggle Zoom", "plus.magnifyingglass", ["zoom", "fullscreen", "maximize"],
                   .yabai([["-m", "window", "--toggle", "zoom-fullscreen"]])),
            window("minimize", "State", "Minimize", "minus.square", ["minimize", "dock"], .yabai([["-m", "window", "--minimize"]])),
            window("close", "State", "Close Window", "xmark.square", ["close"], .yabai([["-m", "window", "--close"]])),
            window("display.next", "Move To", "Move to Next Display", "display.2", ["monitor", "screen"],
                   .yabai([["-m", "window", "--display", "next"]])),
            window("display.previous", "Move To", "Move to Previous Display", "display.2", ["monitor", "screen"],
                   .yabai([["-m", "window", "--display", "prev"]])),
        ]
        for index in 1...9 {
            items.append(window("desktop.\(index)", "Move To", "Move to Desktop \(index)", "\(index).square",
                                ["space", "send"], .moveToDesktop(String(index)), requirement: .scriptingAddition))
        }
        items += [
            window("desktop.next", "Move To", "Move to Next Desktop", "arrow.right.square", ["space", "send"],
                   .moveToDesktop("next"), requirement: .scriptingAddition),
            window("desktop.previous", "Move To", "Move to Previous Desktop", "arrow.left.square", ["space", "send"],
                   .moveToDesktop("prev"), requirement: .scriptingAddition),
        ]
        return items
    }()

    private static let desktopBuiltIns: [KeyboardLayerBuiltIn] = (1...9).map { index in
        KeyboardLayerBuiltIn(
            id: "desktop.go.\(index)", category: .desktops, section: "Go To", title: "Go to Desktop \(index)",
            systemImage: "\(index).square", keywords: ["space", "switch"], requirement: .yabai, work: .goToDesktop(index)
        )
    } + [
        KeyboardLayerBuiltIn(id: "desktop.next", category: .desktops, section: "Go To", title: "Next Desktop",
                             systemImage: "arrow.right.square", keywords: ["space", "switch"], work: .keys([keys(124, .control)])),
        KeyboardLayerBuiltIn(id: "desktop.previous", category: .desktops, section: "Go To", title: "Previous Desktop",
                             systemImage: "arrow.left.square", keywords: ["space", "switch"], work: .keys([keys(123, .control)])),
    ]

    private static let layoutBuiltIns: [KeyboardLayerBuiltIn] = [
        KeyboardLayerBuiltIn(id: "layout.mirror.horizontal", category: .layouts, section: "Tiling", title: "Mirror Horizontally",
                             systemImage: "arrow.left.and.right", keywords: ["flip", "tiled"], requirement: .yabai,
                             work: .yabai([["-m", "space", "--mirror", "y-axis"]])),
        KeyboardLayerBuiltIn(id: "layout.mirror.vertical", category: .layouts, section: "Tiling", title: "Mirror Vertically",
                             systemImage: "arrow.up.and.down", keywords: ["flip", "tiled"], requirement: .yabai,
                             work: .yabai([["-m", "space", "--mirror", "x-axis"]])),
    ]

    private static let appBuiltIns: [KeyboardLayerBuiltIn] = [
        KeyboardLayerBuiltIn(id: "app.front.hide", category: .apps, section: "Front App", title: "Hide Front App",
                             systemImage: "eye.slash", keywords: ["hide"], work: .frontApp(.hide)),
        KeyboardLayerBuiltIn(id: "app.front.hide-others", category: .apps, section: "Front App", title: "Hide Other Apps",
                             systemImage: "eye.slash.circle", keywords: ["hide", "others"], work: .frontApp(.hideOthers)),
        KeyboardLayerBuiltIn(id: "app.front.quit", category: .apps, section: "Front App", title: "Quit Front App",
                             systemImage: "xmark.circle", keywords: ["quit", "close", "exit"], work: .frontApp(.quit)),
    ]

    private static func macOS(
        _ id: String, _ section: String, _ title: String, _ symbol: String, _ keywords: [String], _ work: KeyboardLayerBuiltInWork
    ) -> KeyboardLayerBuiltIn {
        KeyboardLayerBuiltIn(id: "macos.\(id)", category: .macOS, section: section, title: title, systemImage: symbol,
                             keywords: keywords, work: work)
    }

    private static let macOSBuiltIns: [KeyboardLayerBuiltIn] = [
        macOS("mission-control", "Overview", "Mission Control", "square.grid.3x2", ["expose", "spaces", "overview"],
              .overview(yabai: ["-m", "space", "--toggle", "mission-control"], missionControlArgument: nil)),
        macOS("app-expose", "Overview", "App Exposé", "rectangle.stack", ["expose", "windows", "app windows"],
              .overview(yabai: ["-m", "window", "--toggle", "expose"], missionControlArgument: "2")),
        macOS("show-desktop", "Overview", "Show Desktop", "menubar.dock.rectangle", ["desktop", "hide windows"],
              .overview(yabai: ["-m", "space", "--toggle", "show-desktop"], missionControlArgument: "1")),
        macOS("apps", "Overview", "Apps", "square.grid.3x3.fill", ["launchpad", "launcher"],
              .openSystemApp(path: "/System/Applications/Apps.app")),
        macOS("launchpad", "Overview", "Launchpad", "square.grid.3x3.fill", ["apps", "launcher"],
              .openSystemApp(path: "/System/Applications/Launchpad.app")),
        macOS("spotlight", "Input", "Spotlight", "magnifyingglass", ["search", "find"], .keys([keys(49, .command)])),
        macOS("emoji", "Input", "Emoji & Symbols", "face.smiling", ["emoji", "characters", "symbols"],
              .keys([keys(49, [.control, .command])])),
        macOS("lock", "Session", "Lock Screen", "lock", ["lock", "away"], .keys([keys(12, [.control, .command])])),
        macOS("sleep-display", "Session", "Sleep Display", "moon", ["sleep", "screen off"],
              .process(path: "/usr/bin/pmset", arguments: ["displaysleepnow"])),
        macOS("force-quit", "Session", "Force Quit Apps", "exclamationmark.octagon", ["force quit", "kill"],
              .keys([keys(53, [.option, .command])])),
        macOS("screenshot.screen", "Screenshots", "Screenshot of Whole Screen", "camera", ["screenshot", "capture"],
              .keys([keys(20, [.shift, .command])])),
        macOS("screenshot.selection", "Screenshots", "Screenshot of Selection", "crop", ["screenshot", "capture", "area"],
              .keys([keys(21, [.shift, .command])])),
        macOS("screenshot.window", "Screenshots", "Screenshot of Window", "macwindow", ["screenshot", "capture"],
              .keys([keys(21, [.shift, .command]), keys(49, [])])),
        macOS("screenshot.toolbar", "Screenshots", "Screenshot Toolbar", "camera.on.rectangle", ["screenshot", "record", "capture"],
              .keys([keys(23, [.shift, .command])])),
        macOS("media.play-pause", "Media", "Play or Pause", "playpause", ["music", "media"], .systemKey(16)),
        macOS("media.next", "Media", "Next Track", "forward", ["music", "media", "skip"], .systemKey(17)),
        macOS("media.previous", "Media", "Previous Track", "backward", ["music", "media"], .systemKey(18)),
        macOS("volume.up", "Sound", "Volume Up", "speaker.wave.3", ["sound", "louder"], .systemKey(0)),
        macOS("volume.down", "Sound", "Volume Down", "speaker.wave.1", ["sound", "quieter"], .systemKey(1)),
        macOS("volume.mute", "Sound", "Mute", "speaker.slash", ["sound", "silence"], .systemKey(7)),
        macOS("brightness.up", "Display", "Brightness Up", "sun.max", ["screen", "brighter"], .systemKey(2)),
        macOS("brightness.down", "Display", "Brightness Down", "sun.min", ["screen", "dimmer"], .systemKey(3)),
    ]
}

/// Finds installed apps for the key window.
enum KeyboardLayerAppScanner {
    static var standardRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// Apps in each root or up to two folders inside it, never inside other apps, one per bundle
    /// ID, sorted by name.
    static func installedApps(in roots: [URL]) -> [KeyboardLayerApp] {
        var seen: Set<String> = []
        var apps: [KeyboardLayerApp] = []
        func visit(_ folder: URL, depth: Int) {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            for child in children {
                if child.pathExtension == "app" {
                    let app = KeyboardLayerApp(url: child)
                    if seen.insert(app.bundleID ?? child.path).inserted { apps.append(app) }
                } else if depth < 3, (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    visit(child, depth: depth + 1)
                }
            }
        }
        for root in roots { visit(root, depth: 1) }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
