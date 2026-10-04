import Foundation

protocol BehaviorOptionDisplayable {
    var displayName: String { get }
    var pickerDisplayName: String { get }
}

extension BehaviorOptionDisplayable {
    var pickerDisplayName: String { displayName }
}

enum HoverFocusMode: String, Codable, CaseIterable, Sendable, BehaviorOptionDisplayable {
    case off
    case autofocus
    case autoraise

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .autofocus: return "Auto Focus"
        case .autoraise: return "Auto Raise"
        }
    }
}

enum MouseModifierKey: String, Codable, CaseIterable, Sendable, BehaviorOptionDisplayable {
    case cmd
    case alt
    case shift
    case ctrl
    case fn

    var displayName: String {
        switch self {
        case .cmd: return "Command"
        case .alt: return "Option"
        case .shift: return "Shift"
        case .ctrl: return "Control"
        case .fn: return "Fn"
        }
    }

    var pickerDisplayName: String {
        switch self {
        case .cmd: return "⌘ Command"
        case .alt: return "⌥ Option"
        case .shift: return "⇧ Shift"
        case .ctrl: return "⌃ Control"
        case .fn: return "fn Fn"
        }
    }
}

enum MouseDragAction: String, Codable, CaseIterable, Sendable, BehaviorOptionDisplayable {
    case move
    case resize

    var displayName: String {
        switch self {
        case .move: return "Move"
        case .resize: return "Resize"
        }
    }
}

enum MouseDropAction: String, Codable, CaseIterable, Sendable, BehaviorOptionDisplayable {
    case swap
    case stack

    var displayName: String {
        switch self {
        case .swap: return "Swap"
        case .stack: return "Stack"
        }
    }
}

struct ManagedWindowBehaviorPolicy: Codable, Sendable, Equatable {
    var manualTilingModeEnabled: Bool
    var hoverFocusMode: HoverFocusMode
    var mouseFollowsFocusEnabled: Bool
    var outerPadding: Int
    var windowGap: Int
    var mouseModifier: MouseModifierKey
    var mouseAction1: MouseDragAction
    var mouseAction2: MouseDragAction
    var mouseDropAction: MouseDropAction
    var neverTileApps: [String]
    var alwaysTileApps: [String]

    static let `default` = ManagedWindowBehaviorPolicy(
        manualTilingModeEnabled: false,
        hoverFocusMode: .off,
        mouseFollowsFocusEnabled: false,
        outerPadding: 0,
        windowGap: 0,
        mouseModifier: .fn,
        mouseAction1: .move,
        mouseAction2: .resize,
        mouseDropAction: .swap,
        neverTileApps: [],
        alwaysTileApps: []
    )
}

struct YabaiConfigDocumentState: Sendable {
    let filePath: String
    let fileExists: Bool
    let fullContent: String
    let managedSectionBody: String
    let hasManagedSection: Bool
    let backups: [ConfigBackupInfo]
    let policy: ManagedWindowBehaviorPolicy
}

struct YabaiConfigSaveResult: Sendable {
    let filePath: String
    let backups: [ConfigBackupInfo]
    let previousBackup: ConfigBackupInfo?
    let wasInsert: Bool
}

struct YabaiConfigRestoreResult: Sendable {
    let filePath: String
    let backups: [ConfigBackupInfo]
    let restoredBackup: ConfigBackupInfo
    let preRestoreBackup: ConfigBackupInfo?
}

enum AppTilingBehavior: String, Codable, CaseIterable, Sendable {
    case useDefault
    case neverTile
    case alwaysTile

    var displayName: String {
        switch self {
        case .useDefault: return "Default"
        case .neverTile: return "Never Auto-Tile"
        case .alwaysTile: return "Always Tile"
        }
    }
}

enum AppForegroundPolicy: String, Codable, CaseIterable, Sendable {
    case useDefault
    case keepFrontWhenFloating

    var displayName: String {
        switch self {
        case .useDefault: return "Default"
        case .keepFrontWhenFloating: return "Keep on Top"
        }
    }
}
