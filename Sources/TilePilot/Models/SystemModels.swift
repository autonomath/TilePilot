import Foundation

enum CapabilityStatus: String, Codable, CaseIterable, Sendable {
    case available
    case degraded
    case blocked
    case unsupported
    case unknown

    var severityRank: Int {
        switch self {
        case .available: return 0
        case .unknown: return 1
        case .degraded: return 2
        case .unsupported: return 3
        case .blocked: return 4
        }
    }
}

struct CapabilityState: Identifiable, Codable, Sendable {
    let key: String
    let status: CapabilityStatus
    let reasonCode: String?
    let message: String
    let remediationSteps: [String]

    var id: String { key }
}

enum MissionControlCheckStatus: String, Codable, Sendable {
    case pass
    case warning
    case unknown
}

struct MissionControlCheck: Identifiable, Codable, Sendable {
    let key: String
    let expected: String
    let actual: String?
    let status: MissionControlCheckStatus
    let message: String

    var id: String { key }
}

struct MissionControlChecklistItem: Identifiable, Sendable {
    let id: String
    let title: String
    let expectedValue: String
    let actualValue: String?
    let status: MissionControlCheckStatus
    let message: String
}

func buildMissionControlChecklistItems(from checks: [MissionControlCheck]) -> [MissionControlChecklistItem] {
    let knownChecks = [
        MissionControlChecklistDefinition(
            key: "mru-spaces",
            title: "Automatically rearrange Spaces based on most recent use",
            expectedRawValue: "0"
        ),
        MissionControlChecklistDefinition(
            key: "spans-displays",
            title: "Displays have separate Spaces",
            expectedRawValue: "0"
        ),
    ]

    return knownChecks.map { definition in
        if let check = checks.first(where: { $0.key == definition.key }) {
            return MissionControlChecklistItem(
                id: check.id,
                title: definition.title,
                expectedValue: definition.displayValue(for: check.expected),
                actualValue: check.actual.map(definition.displayValue(for:)),
                status: check.status,
                message: check.message
            )
        }

        return MissionControlChecklistItem(
            id: definition.key,
            title: definition.title,
            expectedValue: definition.displayValue(for: definition.expectedRawValue),
            actualValue: nil,
            status: .unknown,
            message: "TilePilot could not verify this setting automatically. Review it manually in Mission Control settings."
        )
    }
}

private struct MissionControlChecklistDefinition {
    let key: String
    let title: String
    let expectedRawValue: String

    func displayValue(for rawValue: String) -> String {
        switch key {
        case "mru-spaces":
            return rawValue == "0" ? "Off" : "On"
        case "spans-displays":
            return rawValue == "0" ? "On" : "Off"
        default:
            return rawValue
        }
    }
}

struct SystemProfile: Codable, Sendable {
    let macOSVersion: String
    let macOSBuild: String?
    let arch: String
    let yabaiVersion: String?
    let skhdVersion: String?
    let detectedAt: Date
}

enum HealthBadgeLevel: String, Codable, Sendable {
    case healthy
    case warning
    case degraded
    case blocked

    var symbolName: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .degraded: return "minus.circle.fill"
        case .blocked: return "xmark.circle.fill"
        }
    }

    var title: String {
        rawValue.capitalized
    }
}

struct DoctorSnapshot: Codable, Sendable {
    let generatedAt: Date
    let systemProfile: SystemProfile
    let capabilities: [CapabilityState]
    let missionControlChecks: [MissionControlCheck]
    let compatibilityWarnings: [String]
    let healthBadge: HealthBadgeLevel
}

enum CommandErrorType: String, Codable, Sendable {
    case launchFailure
    case timeout
    case nonZeroExit
    case none
}

struct CommandResult: Codable, Sendable {
    let command: String
    let startedAt: Date
    let endedAt: Date
    let exitStatus: Int32?
    let stdout: String
    let stderr: String
    let errorType: CommandErrorType

    var durationMs: Int {
        Int(endedAt.timeIntervalSince(startedAt) * 1000)
    }

    var isSuccess: Bool {
        exitStatus == 0 && errorType == .none
    }
}

struct CommandLogEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let command: String
    let startedAt: Date
    let endedAt: Date
    let durationMs: Int
    let exitStatus: Int32?
    let stdoutSnippet: String
    let stderrSnippet: String
    let errorType: CommandErrorType
}

struct DiagnosticsReport: Codable, Sendable {
    let generatedAt: Date
    let systemProfile: SystemProfile
    let health: DoctorSnapshot
    let capabilities: [CapabilityState]
    let recentCommands: [CommandLogEntry]
}

enum SetupCheckState: String, Codable, Sendable {
    case installed
    case missing
    case warning
    case unknown
}

struct SetupCheckItem: Identifiable, Codable, Sendable {
    let id: String
    let title: String
    let state: SetupCheckState
    let detail: String
}

struct SetupBootstrapSnapshot: Codable, Sendable {
    let generatedAt: Date
    let items: [SetupCheckItem]
    let brewPrefix: String?
}

enum SetupGuideStepCategory: String, Sendable {
    case essential
    case recommended
    case featureOptional

    var title: String {
        switch self {
        case .essential: return "Required"
        case .recommended: return "Recommended"
        case .featureOptional: return "Optional"
        }
    }
}

enum SetupGuideStepKind: String, CaseIterable, Identifiable, Sendable {
    case installHelpers
    case startHelperServices
    case accessibility
    case startAtLogon
    case missionControl
    case screenRecording

    var id: String { rawValue }
}

enum SetupGuidePresentationSource: String, Sendable {
    case firstLaunch
    case automatic
    case manual
}

struct SetupGuidePresentationState: Equatable, Sendable {
    var isPresented: Bool
    var source: SetupGuidePresentationSource
    var selectedStepKind: SetupGuideStepKind?
    // Non-nil while the first-launch feature tour is showing; the checklist
    // appears after the tour finishes or is skipped.
    var welcomePageIndex: Int?

    static let hidden = SetupGuidePresentationState(isPresented: false, source: .manual, selectedStepKind: nil, welcomePageIndex: nil)
}

struct SetupGuideStep: Identifiable, Sendable {
    let kind: SetupGuideStepKind
    let category: SetupGuideStepCategory
    let title: String
    let summary: String
    let whyItMatters: String
    let whatToDo: String
    let detail: String?
    let verificationText: String?
    let status: SystemCheckStatus
    let isBlocking: Bool
    let isSkippable: Bool
    let primaryAction: SystemCheckAction?
    let secondaryActions: [SystemCheckAction]

    var id: SetupGuideStepKind { kind }

    var isSatisfied: Bool {
        status == .good
    }

    var displayedSecondaryActions: [SystemCheckAction] {
        var seen = Set<SystemCheckAction>()
        return secondaryActions.filter { action in
            guard !(isSatisfied && action == .recheck) else { return false }
            guard action != primaryAction else { return false }
            return seen.insert(action).inserted
        }
    }
}

enum ExistingHelperInstallSource: String, Sendable {
    case homebrew
    case launchAgent
    case binaryOnly

    var title: String {
        switch self {
        case .homebrew:
            return "Homebrew"
        case .launchAgent:
            return "LaunchAgent"
        case .binaryOnly:
            return "External Binary"
        }
    }
}

struct ExistingHelperInstall: Identifiable, Sendable {
    let helper: ManagedHelperKind
    let binaryPath: String?
    let runningExternally: Bool
    let source: ExistingHelperInstallSource
    let launchAgentPath: String?

    var id: String { helper.rawValue }

    var summaryLine: String {
        var parts = [helper.displayName]
        if let binaryPath {
            parts.append(binaryPath)
        } else {
            parts.append(source.title)
        }
        if runningExternally {
            parts.append("running")
        }
        return parts.joined(separator: " · ")
    }
}

struct HelperMigrationPromptState: Identifiable, Sendable {
    let installs: [ExistingHelperInstall]

    var id: String {
        installs.map(\.id).joined(separator: "-")
    }

    var title: String {
        "Existing Helper Install Detected"
    }

    var message: String {
        let details = installs.map(\.summaryLine).joined(separator: "\n")
        return """
        TilePilot found an existing yabai/skhd setup.

        \(details)

        Choose whether to keep using that install or replace it with TilePilot-managed local components.
        """
    }
}

enum SetupNextAction: String, Codable, Sendable {
    case installHelpers
    case reviewAccessibility
    case startHelperServices
    case recheck
    case ready

    var buttonTitle: String {
        switch self {
        case .installHelpers: return "Retry Component Install"
        case .reviewAccessibility: return "Review Accessibility"
        case .startHelperServices: return "Start Window Control"
        case .recheck: return "Recheck Setup"
        case .ready: return "Ready"
        }
    }

    var summaryTitle: String {
        switch self {
        case .installHelpers: return "Preparing Window Control"
        case .reviewAccessibility: return "Accessibility Review Needed"
        case .startHelperServices: return "Window Control Not Running"
        case .recheck: return "Setup Needs Recheck"
        case .ready: return "Ready"
        }
    }
}

enum SystemCheckStatus: String, Sendable {
    case good
    case notice
    case warning
    case error

    var severityRank: Int {
        switch self {
        case .good: return 0
        case .notice: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    var symbolName: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .notice: return "questionmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}

enum SystemCheckAction: String, Sendable, Hashable {
    case installDependencies
    case startYabai
    case startSkhd
    case runGuidedSetup
    case enableStartAtLogon
    case openLoginItemsSettings
    case openAccessibilitySettings
    case requestAccessibilityAccess
    case requestScreenRecordingAccess
    case openScreenRecordingSettings
    case fixScriptingAddition
    case openMissionControlSettings
    case openMissionControlKeyboardShortcuts
    case restartYabai
    case restartSkhd
    case checkForUpdates
    case openLatestReleasePage
    case recheck

    var label: String {
        switch self {
        case .installDependencies: return "Install Components"
        case .startYabai: return "Start yabai"
        case .startSkhd: return "Start skhd"
        case .runGuidedSetup: return "Run Guided Setup"
        case .enableStartAtLogon: return "Enable"
        case .openLoginItemsSettings: return "Login Items"
        case .openAccessibilitySettings: return "Open Settings"
        case .requestAccessibilityAccess: return "Request Access"
        case .requestScreenRecordingAccess: return "Enable Screen Recording"
        case .openScreenRecordingSettings: return "Open Settings"
        case .fixScriptingAddition: return "Fix"
        case .openMissionControlSettings: return "Mission Control"
        case .openMissionControlKeyboardShortcuts: return "Keyboard Shortcuts"
        case .restartYabai: return "Restart yabai"
        case .restartSkhd: return "Restart skhd"
        case .checkForUpdates: return "Check for Updates"
        case .openLatestReleasePage: return "Open Release Page"
        case .recheck: return "Recheck"
        }
    }
}

struct SystemCheckRow: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let status: SystemCheckStatus
    let actions: [SystemCheckAction]
}

enum SystemPanelSection: String, Sendable {
    case essentials
    case files
    case managedConfig
    case diagnostics
}
