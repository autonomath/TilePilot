import Foundation

struct ShortcutEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let combo: String
    let command: String
    let category: String
    let sourceLine: Int
    let sourceFile: String
    let warning: String?

    var stableKey: String {
        "\(combo)\n\(command)"
    }
}

enum DirectionalShortcutGroup: String, CaseIterable, Codable, Sendable {
    case focusWindow
    case moveWindow
    case resizeWindow
    case swapWindow

    var title: String {
        switch self {
        case .focusWindow: return "Focus Window (Direction Keys)"
        case .moveWindow: return "Move Window in Layout (Direction Keys)"
        case .resizeWindow: return "Resize Window (Direction Keys)"
        case .swapWindow: return "Swap Window (Direction Keys)"
        }
    }

    var menuTitle: String {
        switch self {
        case .focusWindow: return "Focus (IJKL)"
        case .moveWindow: return "Move Window (IJKL)"
        case .resizeWindow: return "Resize Window (IJKL)"
        case .swapWindow: return "Swap Window (IJKL)"
        }
    }
}

enum DirectionalShortcutDirection: String, CaseIterable, Codable, Sendable {
    case up
    case left
    case down
    case right

    var sortRank: Int {
        switch self {
        case .up: return 0
        case .left: return 1
        case .down: return 2
        case .right: return 3
        }
    }

    var label: String {
        switch self {
        case .up: return "Up"
        case .left: return "Left"
        case .down: return "Down"
        case .right: return "Right"
        }
    }

    var arrow: String {
        switch self {
        case .up: return "↑"
        case .left: return "←"
        case .down: return "↓"
        case .right: return "→"
        }
    }
}

struct DirectionalShortcutBinding: Identifiable, Sendable {
    let group: DirectionalShortcutGroup
    let direction: DirectionalShortcutDirection
    let entry: ShortcutEntry

    var id: String {
        "\(group.rawValue)-\(direction.rawValue)-\(entry.stableKey)"
    }
}

enum UnifiedControlGroup: String, CaseIterable, Codable, Sendable {
    case desktops
    case templates
    case workSets
    case windowPlacement
    case tilingLayout
    case windowSize
    case helpersScripts
    case apps
    case focus
    case displays
    case automation
    case other
    case experimental

    var title: String {
        switch self {
        case .desktops: return "Desktops"
        case .templates: return "Templates"
        case .workSets: return "Work Sets"
        case .windowPlacement: return "Window Placement"
        case .tilingLayout: return "Tiling & Layout"
        case .windowSize: return "Window Size"
        case .helpersScripts: return "Helpers & Scripts"
        case .apps: return "Apps"
        case .focus: return "Focus"
        case .displays: return "Displays"
        case .automation: return "Automation"
        case .other: return "Other"
        case .experimental: return "Desktop Move (Experimental)"
        }
    }

    var systemImage: String {
        switch self {
        case .desktops: return "rectangle.3.group"
        case .templates: return "rectangle.3.offgrid"
        case .workSets: return "square.stack.3d.up"
        case .windowPlacement: return "macwindow.on.rectangle"
        case .tilingLayout: return "square.grid.3x3"
        case .windowSize: return "arrow.up.left.and.arrow.down.right"
        case .helpersScripts: return "terminal"
        case .apps: return "app"
        case .focus: return "cursorarrow.motionlines"
        case .displays: return "display.2"
        case .automation: return "bolt.horizontal"
        case .other: return "ellipsis.circle"
        case .experimental: return "flask"
        }
    }

    var sortRank: Int {
        switch self {
        case .desktops: return 0
        case .templates: return 1
        case .workSets: return 2
        case .windowPlacement: return 3
        case .tilingLayout: return 4
        case .windowSize: return 5
        case .helpersScripts: return 6
        case .apps: return 7
        case .focus: return 8
        case .displays: return 9
        case .automation: return 10
        case .other: return 98
        case .experimental: return 99
        }
    }
}

struct ShortcutsCatalogSection: Identifiable, Sendable {
    let group: UnifiedControlGroup
    let items: [ShortcutsDisplayItem]

    var id: String { group.rawValue }
}

struct UnifiedControlRow: Identifiable, Sendable {
    let id: String
    let group: UnifiedControlGroup
    let title: String
    let description: String
    let shortcutEntry: ShortcutEntry?
    let actionID: TilePilotActionID?
    let secondaryActionIDs: [TilePilotActionID]
    let isExperimental: Bool
    let disabledReason: String?
    let intentKey: String
    let featureID: FeatureControlID?
}

struct FeatureControlID: RawRepresentable, Hashable, Codable, Sendable, Identifiable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    var id: String { rawValue }
}

enum FeatureExecutionBackend: String, Codable, Sendable {
    case shortcutCommand
    case tilePilotAction
    case scriptPath
}

enum FeatureCapabilityGate: String, Codable, Sendable {
    case none
    case yabaiRuntime
    case scriptingAddition
}

enum FeatureShortcutBindingState: Sendable, Equatable {
    case assigned(combo: String)
    case missing(defaultCombo: String?)
    case conflict(combo: String, conflictingFeatureTitle: String, suggestions: [String])
    case disabled(reason: String)
}

enum FeatureRunSource: String, Sendable {
    case shortcutsUI
    case statusMenu
}

struct FeatureControlRow: Identifiable, Sendable {
    let id: String
    let featureID: FeatureControlID?
    let group: UnifiedControlGroup
    let title: String
    let description: String
    let backend: FeatureExecutionBackend
    let capabilityGate: FeatureCapabilityGate
    let shortcutEntry: ShortcutEntry?
    let actionID: TilePilotActionID?
    let preferredCommand: String?
    let assignedCombo: String?
    let defaultCombo: String?
    let bindingState: FeatureShortcutBindingState
    let isExperimental: Bool
    let disabledReason: String?
}

enum ShortcutsDisplayItem: Identifiable, Sendable {
    case featureRow(FeatureControlRow)
    case directionalFamily(group: DirectionalShortcutGroup, bindings: [DirectionalShortcutBinding])
    case desktopJumpFamily(entries: [ShortcutEntry])
    case desktopMoveFamily(entries: [ShortcutEntry])

    var id: String {
        switch self {
        case .featureRow(let row):
            if let featureID = row.featureID {
                return "feature.\(featureID.rawValue)"
            }
            if let stableKey = row.shortcutEntry?.stableKey {
                return "shortcut.\(stableKey)"
            }
            if let actionID = row.actionID {
                return "action.\(actionID.rawValue)"
            }
            return "row.\(row.id)"
        case .directionalFamily(let group, _):
            return "directional.\(group.rawValue)"
        case .desktopJumpFamily:
            return "family.desktop-jump"
        case .desktopMoveFamily:
            return "family.desktop-move"
        }
    }
}

enum PinnedShortcutContextItem: Identifiable, Sendable {
    case feature(FeatureControlRow)
    case directional(group: DirectionalShortcutGroup, bindings: [DirectionalShortcutBinding])
    case shortcut(ShortcutEntry)

    var id: String {
        switch self {
        case .feature(let row):
            if let featureID = row.featureID {
                return "feature.\(featureID.rawValue)"
            }
            if let stableKey = row.shortcutEntry?.stableKey {
                return "shortcut.\(stableKey)"
            }
            return "feature-row.\(row.id)"
        case .directional(let group, _):
            return "directional.\(group.rawValue)"
        case .shortcut(let entry):
            return "shortcut.\(entry.stableKey)"
        }
    }
}
