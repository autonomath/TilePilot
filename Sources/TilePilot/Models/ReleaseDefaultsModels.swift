import Foundation

enum ReleaseDefaultsApplyMode: String, Codable, Sendable {
    case firstInstall
    case manualReset
}

struct ReleaseDefaultsUserState: Codable, Sendable {
    let pinnedFeatureControlIDs: [String]
    let pinnedDirectionalGroupIDs: [String]
    let shortcutsCustomOrderIDs: [String]
    let windowLayoutTemplates: [WindowLayoutTemplate]
    let workSets: [WorkSet]
    let activeWorkSetIDsByScope: [String: String]
    let showWindowBadgeOverlay: Bool
    let showWindowOutlineOverlay: Bool
    let windowOutlineOverlayBaseWidth: Double
    let tiledOverlayAccentColor: OverlayAccentColor
    let floatingOverlayAccentColor: OverlayAccentColor
    let desktopScrubEnabled: Bool
    let desktopScrubTriggerModifiers: [DesktopScrubModifier]
    let desktopScrubTriggerCharacter: DesktopScrubCharacterKey
    let desktopScrubSensitivity: Double
    let desktopScrubInvertDirection: Bool
    let raiseOnFloatToggleEnabled: Bool
    let appForegroundPolicyByName: [String: AppForegroundPolicy]
    let performanceSettings: PerformanceSettings

    init(
        pinnedFeatureControlIDs: [String],
        pinnedDirectionalGroupIDs: [String],
        shortcutsCustomOrderIDs: [String] = [],
        windowLayoutTemplates: [WindowLayoutTemplate] = [],
        workSets: [WorkSet] = [],
        activeWorkSetIDsByScope: [String: String] = [:],
        showWindowBadgeOverlay: Bool,
        showWindowOutlineOverlay: Bool,
        windowOutlineOverlayBaseWidth: Double,
        tiledOverlayAccentColor: OverlayAccentColor,
        floatingOverlayAccentColor: OverlayAccentColor,
        desktopScrubEnabled: Bool,
        desktopScrubTriggerModifiers: [DesktopScrubModifier],
        desktopScrubTriggerCharacter: DesktopScrubCharacterKey,
        desktopScrubSensitivity: Double,
        desktopScrubInvertDirection: Bool,
        raiseOnFloatToggleEnabled: Bool,
        appForegroundPolicyByName: [String: AppForegroundPolicy],
        performanceSettings: PerformanceSettings
    ) {
        self.pinnedFeatureControlIDs = pinnedFeatureControlIDs
        self.pinnedDirectionalGroupIDs = pinnedDirectionalGroupIDs
        self.shortcutsCustomOrderIDs = shortcutsCustomOrderIDs
        self.windowLayoutTemplates = windowLayoutTemplates
        self.workSets = workSets
        self.activeWorkSetIDsByScope = activeWorkSetIDsByScope
        self.showWindowBadgeOverlay = showWindowBadgeOverlay
        self.showWindowOutlineOverlay = showWindowOutlineOverlay
        self.windowOutlineOverlayBaseWidth = windowOutlineOverlayBaseWidth
        self.tiledOverlayAccentColor = tiledOverlayAccentColor
        self.floatingOverlayAccentColor = floatingOverlayAccentColor
        self.desktopScrubEnabled = desktopScrubEnabled
        self.desktopScrubTriggerModifiers = DesktopScrubModifier.normalize(desktopScrubTriggerModifiers)
        self.desktopScrubTriggerCharacter = desktopScrubTriggerCharacter
        self.desktopScrubSensitivity = desktopScrubSensitivity
        self.desktopScrubInvertDirection = desktopScrubInvertDirection
        self.raiseOnFloatToggleEnabled = raiseOnFloatToggleEnabled
        self.appForegroundPolicyByName = appForegroundPolicyByName
        self.performanceSettings = performanceSettings
    }

    private enum CodingKeys: String, CodingKey {
        case pinnedFeatureControlIDs
        case pinnedDirectionalGroupIDs
        case shortcutsCustomOrderIDs
        case windowLayoutTemplates
        case workSets
        case activeWorkSetIDsByScope
        case showWindowBadgeOverlay
        case showWindowOutlineOverlay
        case windowOutlineOverlayBaseWidth
        case tiledOverlayAccentColor
        case floatingOverlayAccentColor
        case desktopScrubEnabled
        case desktopScrubTriggerModifiers
        case desktopScrubTriggerCharacter
        case desktopScrubSensitivity
        case desktopScrubInvertDirection
        case raiseOnFloatToggleEnabled
        case appForegroundPolicyByName
        case performanceSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pinnedFeatureControlIDs = try container.decode([String].self, forKey: .pinnedFeatureControlIDs)
        pinnedDirectionalGroupIDs = try container.decode([String].self, forKey: .pinnedDirectionalGroupIDs)
        shortcutsCustomOrderIDs = try container.decodeIfPresent([String].self, forKey: .shortcutsCustomOrderIDs) ?? []
        windowLayoutTemplates = try container.decodeIfPresent([WindowLayoutTemplate].self, forKey: .windowLayoutTemplates) ?? []
        workSets = try container.decodeIfPresent([WorkSet].self, forKey: .workSets) ?? []
        activeWorkSetIDsByScope = try container.decodeIfPresent([String: String].self, forKey: .activeWorkSetIDsByScope) ?? [:]
        showWindowBadgeOverlay = try container.decode(Bool.self, forKey: .showWindowBadgeOverlay)
        showWindowOutlineOverlay = try container.decode(Bool.self, forKey: .showWindowOutlineOverlay)
        windowOutlineOverlayBaseWidth = try container.decodeIfPresent(Double.self, forKey: .windowOutlineOverlayBaseWidth) ?? 2.0
        tiledOverlayAccentColor = try container.decodeIfPresent(OverlayAccentColor.self, forKey: .tiledOverlayAccentColor) ?? .tiledDefault
        floatingOverlayAccentColor = try container.decodeIfPresent(OverlayAccentColor.self, forKey: .floatingOverlayAccentColor) ?? .floatingDefault
        desktopScrubEnabled = try container.decodeIfPresent(Bool.self, forKey: .desktopScrubEnabled) ?? true
        desktopScrubTriggerModifiers = DesktopScrubModifier.loadFromUserDefaults(
            rawValues: try container.decodeIfPresent([String].self, forKey: .desktopScrubTriggerModifiers)
        )
        desktopScrubTriggerCharacter = try container.decodeIfPresent(DesktopScrubCharacterKey.self, forKey: .desktopScrubTriggerCharacter) ?? .none
        desktopScrubSensitivity = try container.decodeIfPresent(Double.self, forKey: .desktopScrubSensitivity) ?? 1.0
        desktopScrubInvertDirection = try container.decodeIfPresent(Bool.self, forKey: .desktopScrubInvertDirection) ?? true
        raiseOnFloatToggleEnabled = try container.decode(Bool.self, forKey: .raiseOnFloatToggleEnabled)
        appForegroundPolicyByName = try container.decode([String: AppForegroundPolicy].self, forKey: .appForegroundPolicyByName)
        performanceSettings = try container.decodeIfPresent(PerformanceSettings.self, forKey: .performanceSettings) ?? .balanced
    }
}

struct ReleaseDefaultsConfigState: Codable, Sendable {
    let managedSkhdSectionBody: String
    let windowBehaviorPolicy: ManagedWindowBehaviorPolicy
}

struct ReleaseDefaultsProfile: Codable, Sendable {
    let profileVersion: String
    let userState: ReleaseDefaultsUserState
    let configState: ReleaseDefaultsConfigState
}

enum ReleaseDefaultsStatus: Sendable, Equatable {
    case upToDate(version: String)
    case updateAvailable(currentVersion: String, lastAppliedVersion: String)
    case neverApplied(currentVersion: String)

    var summaryText: String {
        switch self {
        case .upToDate(let version):
            return "Release defaults \(version) are applied."
        case .updateAvailable(let currentVersion, let lastAppliedVersion):
            return "New release defaults available (\(lastAppliedVersion) -> \(currentVersion))."
        case .neverApplied(let currentVersion):
            return "Release defaults \(currentVersion) have not been applied yet."
        }
    }

    var currentVersion: String {
        switch self {
        case .upToDate(let version):
            return version
        case .updateAvailable(let currentVersion, _):
            return currentVersion
        case .neverApplied(let currentVersion):
            return currentVersion
        }
    }
}
