import Foundation

struct TilePilotActionMeta: Sendable {
    let title: String
    let subtitle: String
    let category: String
    let buttonLabel: String
    let requiredCapabilities: [String]
    let requiresLiveState: Bool
    let disableInDegradedMode: Bool
}

enum TilePilotActionCatalog {
    static func meta(for actionID: TilePilotActionID) -> TilePilotActionMeta {
        switch actionID {
        case .balanceSpace:
            return .init(
                title: "Rebalance Tiled Window Sizes",
                subtitle: "Redistribute space so tiled windows on this desktop are closer in size",
                category: "Layouts",
                buttonLabel: "Rebalance",
                requiredCapabilities: ["yabai-binary", "yabai-daemon", "yabai-query"],
                requiresLiveState: true,
                disableInDegradedMode: true
            )
        case .layoutBSPAndBalance:
            return .init(
                title: "Set This Desktop to Tiled Layout and Rebalance",
                subtitle: "Turn on tiled layout for this desktop and rebalance existing tiles",
                category: "Layouts",
                buttonLabel: "Set Tiled",
                requiredCapabilities: ["yabai-binary", "yabai-daemon", "yabai-query"],
                requiresLiveState: true,
                disableInDegradedMode: true
            )
        case .layoutStack:
            return .init(
                title: "Stack Layout",
                subtitle: "Show windows in a stack layout on the current desktop",
                category: "Layouts",
                buttonLabel: "Set Stack Layout",
                requiredCapabilities: ["yabai-binary", "yabai-daemon", "yabai-query"],
                requiresLiveState: true,
                disableInDegradedMode: true
            )
        case .toggleFloat:
            return .init(
                title: "Toggle Float/Tile",
                subtitle: "Switch the focused window between floating and tiled",
                category: "Window",
                buttonLabel: "Toggle",
                requiredCapabilities: ["yabai-binary", "yabai-daemon", "yabai-query"],
                requiresLiveState: true,
                disableInDegradedMode: false
            )
        case .focusWest:
            return .init(
                title: "Focus Left",
                subtitle: "Move focus to the window on the left",
                category: "Focus",
                buttonLabel: "Focus Left",
                requiredCapabilities: ["yabai-binary", "yabai-daemon", "yabai-query"],
                requiresLiveState: true,
                disableInDegradedMode: false
            )
        case .focusEast:
            return .init(
                title: "Focus Right",
                subtitle: "Move focus to the window on the right",
                category: "Focus",
                buttonLabel: "Focus Right",
                requiredCapabilities: ["yabai-binary", "yabai-daemon", "yabai-query"],
                requiresLiveState: true,
                disableInDegradedMode: false
            )
        case .focusNorth:
            return .init(
                title: "Focus Up",
                subtitle: "Move focus to the window above",
                category: "Focus",
                buttonLabel: "Focus Up",
                requiredCapabilities: ["yabai-binary", "yabai-daemon", "yabai-query"],
                requiresLiveState: true,
                disableInDegradedMode: false
            )
        case .focusSouth:
            return .init(
                title: "Focus Down",
                subtitle: "Move focus to the window below",
                category: "Focus",
                buttonLabel: "Focus Down",
                requiredCapabilities: ["yabai-binary", "yabai-daemon", "yabai-query"],
                requiresLiveState: true,
                disableInDegradedMode: false
            )
        case .browserReliefPlaceholder:
            return .init(
                title: "Browser Relief",
                subtitle: "Planned helper workflow",
                category: "Layouts",
                buttonLabel: "Run",
                requiredCapabilities: ["yabai-binary"],
                requiresLiveState: false,
                disableInDegradedMode: true
            )
        }
    }

    static func commands(for actionID: TilePilotActionID) -> [ShellCommand] {
        switch actionID {
        case .balanceSpace:
            return [yabaiCommand(["-m", "space", "--balance"], timeout: 1.5)]
        case .layoutBSPAndBalance:
            return [
                yabaiCommand(["-m", "space", "--layout", "bsp"], timeout: 1.5),
                yabaiCommand(["-m", "space", "--balance"], timeout: 1.5),
            ]
        case .layoutStack:
            return [yabaiCommand(["-m", "space", "--layout", "stack"], timeout: 1.5)]
        case .toggleFloat:
            return [yabaiCommand(["-m", "window", "--toggle", "float"], timeout: 1.5)]
        case .focusWest:
            return [yabaiCommand(["-m", "window", "--focus", "west"], timeout: 1.5)]
        case .focusEast:
            return [yabaiCommand(["-m", "window", "--focus", "east"], timeout: 1.5)]
        case .focusNorth:
            return [yabaiCommand(["-m", "window", "--focus", "north"], timeout: 1.5)]
        case .focusSouth:
            return [yabaiCommand(["-m", "window", "--focus", "south"], timeout: 1.5)]
        case .browserReliefPlaceholder:
            return []
        }
    }

    static func userFacingDisabledReason(forCapabilityKey key: String, capability: CapabilityState) -> String {
        switch key {
        case "yabai-binary":
            return "Install yabai first."
        case "yabai-daemon":
            return "Start yabai, then try again."
        case "yabai-query":
            return "TilePilot can’t read yabai right now. Restart yabai and try again."
        default:
            return capability.message
        }
    }

    static func failureMessage(for actionID: TilePilotActionID, commandResult result: CommandResult) -> String {
        let stderr = trimForUI(result.stderr).lowercased()
        let title = meta(for: actionID).title

        if stderr.contains("could not connect") {
            return "\(title) didn’t run because yabai is not responding. Start or restart yabai, then try again."
        }
        if stderr.contains("no such file") || stderr.contains("not found") {
            return "\(title) didn’t run because yabai is not installed."
        }
        if stderr.contains("scripting-addition") {
            return "\(title) is not supported by TilePilot on this setup."
        }
        let trimmed = trimForUI(result.stderr)
        if trimmed.isEmpty {
            return "\(title) didn’t work."
        }
        return "\(title) didn’t work: \(trimmed)"
    }
}
