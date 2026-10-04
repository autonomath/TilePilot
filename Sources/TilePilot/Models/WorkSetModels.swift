import Foundation
#if canImport(AppKit)
import AppKit
#endif

struct WorkSetScopeKey: Codable, Hashable, Sendable, Identifiable {
    let displayID: Int
    let spaceIndex: Int

    var id: String {
        "display-\(displayID)-space-\(spaceIndex)"
    }
}

struct WorkSetMember: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let appName: String
    let windowTitle: String
    let role: String
    let subrole: String
    let lastSeenWindowID: Int?
    let lastSeenPID: Int?
    let bundleIdentifier: String?
    let bundleURLPath: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case appName
        case windowTitle
        case role
        case subrole
        case lastSeenWindowID
        case lastSeenPID
        case bundleIdentifier
        case bundleURLPath
    }

    init(
        id: UUID = UUID(),
        appName: String,
        windowTitle: String,
        role: String,
        subrole: String,
        lastSeenWindowID: Int? = nil,
        lastSeenPID: Int? = nil,
        bundleIdentifier: String? = nil,
        bundleURLPath: String? = nil
    ) {
        self.id = id
        self.appName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.windowTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subrole = subrole.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lastSeenWindowID = lastSeenWindowID
        self.lastSeenPID = lastSeenPID
        self.bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.bundleURLPath = bundleURLPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        appName = try container.decode(String.self, forKey: .appName).trimmingCharacters(in: .whitespacesAndNewlines)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        subrole = try container.decodeIfPresent(String.self, forKey: .subrole)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lastSeenWindowID = try container.decodeIfPresent(Int.self, forKey: .lastSeenWindowID)
        lastSeenPID = try container.decodeIfPresent(Int.self, forKey: .lastSeenPID)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        bundleURLPath = try container.decodeIfPresent(String.self, forKey: .bundleURLPath)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    init(window: WindowState) {
        #if canImport(AppKit)
        let runningApp = NSRunningApplication(processIdentifier: pid_t(window.pid))
        let resolvedBundleIdentifier = runningApp?.bundleIdentifier
        let resolvedBundleURLPath = runningApp?.bundleURL?.path
        #else
        let resolvedBundleIdentifier: String? = nil
        let resolvedBundleURLPath: String? = nil
        #endif
        self.init(
            appName: window.app,
            windowTitle: window.title,
            role: window.role,
            subrole: window.subrole,
            lastSeenWindowID: window.id,
            lastSeenPID: window.pid,
            bundleIdentifier: resolvedBundleIdentifier,
            bundleURLPath: resolvedBundleURLPath
        )
    }

    func with(
        appName: String? = nil,
        windowTitle: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        lastSeenWindowID: Int?? = nil,
        lastSeenPID: Int?? = nil,
        bundleIdentifier: String?? = nil,
        bundleURLPath: String?? = nil
    ) -> WorkSetMember {
        WorkSetMember(
            id: id,
            appName: appName ?? self.appName,
            windowTitle: windowTitle ?? self.windowTitle,
            role: role ?? self.role,
            subrole: subrole ?? self.subrole,
            lastSeenWindowID: lastSeenWindowID ?? self.lastSeenWindowID,
            lastSeenPID: lastSeenPID ?? self.lastSeenPID,
            bundleIdentifier: bundleIdentifier ?? self.bundleIdentifier,
            bundleURLPath: bundleURLPath ?? self.bundleURLPath
        )
    }
}

enum WorkSetLayoutMode: String, Codable, CaseIterable, Hashable, Sendable {
    case stackOnly
    case tiled
    case template

    var title: String {
        switch self {
        case .stackOnly:
            return "Floating"
        case .tiled:
            return "Tile"
        case .template:
            return "Template"
        }
    }
}

struct WorkSet: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let sourceDisplayName: String
    let sourceDisplayWidth: Double?
    let sourceDisplayHeight: Double?
    let sourceDisplayShapeKey: DisplayShapeKey?
    let scopeKey: WorkSetScopeKey
    let members: [WorkSetMember]
    let layoutMode: WorkSetLayoutMode
    let linkedTemplateID: UUID?
    let launchMissingApps: Bool
    let backdropEnabled: Bool
    let backdropColor: OverlayAccentColor

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case sourceDisplayName
        case sourceDisplayWidth
        case sourceDisplayHeight
        case sourceDisplayShapeKey
        case scopeKey
        case members
        case layoutMode
        case linkedTemplateID
        case launchMissingApps
        case backdropEnabled
        case backdropColor
    }

    init(
        id: UUID = UUID(),
        name: String,
        sourceDisplayName: String,
        sourceDisplayWidth: Double? = nil,
        sourceDisplayHeight: Double? = nil,
        sourceDisplayShapeKey: DisplayShapeKey? = nil,
        scopeKey: WorkSetScopeKey,
        members: [WorkSetMember],
        layoutMode: WorkSetLayoutMode = .stackOnly,
        linkedTemplateID: UUID? = nil,
        launchMissingApps: Bool = false,
        backdropEnabled: Bool = false,
        backdropColor: OverlayAccentColor = .workSetBackdropDefault
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceDisplayName = sourceDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceDisplayWidth = sourceDisplayWidth
        self.sourceDisplayHeight = sourceDisplayHeight
        self.sourceDisplayShapeKey = sourceDisplayShapeKey ?? {
            guard let sourceDisplayWidth, let sourceDisplayHeight else { return nil }
            return DisplayShapeKey.from(width: sourceDisplayWidth, height: sourceDisplayHeight)
        }()
        self.scopeKey = scopeKey
        self.members = members
        self.layoutMode = layoutMode
        self.linkedTemplateID = linkedTemplateID
        self.launchMissingApps = launchMissingApps
        self.backdropEnabled = backdropEnabled
        self.backdropColor = backdropColor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
        sourceDisplayName = try container.decodeIfPresent(String.self, forKey: .sourceDisplayName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Current Display"
        let decodedSourceDisplayWidth = try container.decodeIfPresent(Double.self, forKey: .sourceDisplayWidth)
        let decodedSourceDisplayHeight = try container.decodeIfPresent(Double.self, forKey: .sourceDisplayHeight)
        sourceDisplayWidth = decodedSourceDisplayWidth
        sourceDisplayHeight = decodedSourceDisplayHeight
        sourceDisplayShapeKey = try container.decodeIfPresent(DisplayShapeKey.self, forKey: .sourceDisplayShapeKey)
            ?? {
                guard let decodedSourceDisplayWidth, let decodedSourceDisplayHeight else { return nil }
                return DisplayShapeKey.from(width: decodedSourceDisplayWidth, height: decodedSourceDisplayHeight)
            }()
        scopeKey = try container.decode(WorkSetScopeKey.self, forKey: .scopeKey)
        members = try container.decodeIfPresent([WorkSetMember].self, forKey: .members) ?? []
        layoutMode = try container.decodeIfPresent(WorkSetLayoutMode.self, forKey: .layoutMode) ?? .stackOnly
        linkedTemplateID = try container.decodeIfPresent(UUID.self, forKey: .linkedTemplateID)
        launchMissingApps = try container.decodeIfPresent(Bool.self, forKey: .launchMissingApps) ?? false
        backdropEnabled = try container.decodeIfPresent(Bool.self, forKey: .backdropEnabled) ?? false
        backdropColor = try container.decodeIfPresent(OverlayAccentColor.self, forKey: .backdropColor) ?? .workSetBackdropDefault
    }

    func with(
        name: String? = nil,
        sourceDisplayName: String? = nil,
        sourceDisplayWidth: Double?? = nil,
        sourceDisplayHeight: Double?? = nil,
        sourceDisplayShapeKey: DisplayShapeKey?? = nil,
        scopeKey: WorkSetScopeKey? = nil,
        members: [WorkSetMember]? = nil,
        layoutMode: WorkSetLayoutMode? = nil,
        linkedTemplateID: UUID?? = nil,
        launchMissingApps: Bool? = nil,
        backdropEnabled: Bool? = nil,
        backdropColor: OverlayAccentColor? = nil
    ) -> WorkSet {
        WorkSet(
            id: id,
            name: name ?? self.name,
            sourceDisplayName: sourceDisplayName ?? self.sourceDisplayName,
            sourceDisplayWidth: sourceDisplayWidth ?? self.sourceDisplayWidth,
            sourceDisplayHeight: sourceDisplayHeight ?? self.sourceDisplayHeight,
            sourceDisplayShapeKey: sourceDisplayShapeKey ?? self.sourceDisplayShapeKey,
            scopeKey: scopeKey ?? self.scopeKey,
            members: members ?? self.members,
            layoutMode: layoutMode ?? self.layoutMode,
            linkedTemplateID: linkedTemplateID ?? self.linkedTemplateID,
            launchMissingApps: launchMissingApps ?? self.launchMissingApps,
            backdropEnabled: backdropEnabled ?? self.backdropEnabled,
            backdropColor: backdropColor ?? self.backdropColor
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

struct WorkSetBackdropPresentation: Equatable, Sendable {
    let workSetID: UUID
    let scopeKey: WorkSetScopeKey
    let display: DisplayState
    let color: OverlayAccentColor
    let anchorWindow: WindowState?
}

enum WorkSetMemberMatchStatus: String, Sendable {
    case exact
    case sameApp
    case minimized
    case otherDesktop
    case otherScreen
    case missing

    var label: String {
        switch self {
        case .exact:
            return "Exact"
        case .sameApp:
            return "Same App"
        case .minimized:
            return "Minimized"
        case .otherDesktop:
            return "Other Desktop"
        case .otherScreen:
            return "Other Screen"
        case .missing:
            return "Missing"
        }
    }
}

struct WorkSetResolvedMember: Identifiable, Sendable {
    let member: WorkSetMember
    let matchedWindow: WindowState?
    let status: WorkSetMemberMatchStatus

    var id: UUID { member.id }
}

enum WorkSetDropPayload: Sendable {
    case member(sourceWorkSetID: UUID, memberID: UUID)
    case window(WorkSetMember)
}

func nextWorkSetToCycle(in workSets: [WorkSet], activeWorkSetID: UUID?) -> WorkSet? {
    guard !workSets.isEmpty else { return nil }
    guard let activeWorkSetID,
          let activeIndex = workSets.firstIndex(where: { $0.id == activeWorkSetID }) else {
        return workSets.first
    }
    let nextIndex = (activeIndex + 1) % workSets.count
    return workSets[nextIndex]
}

func resolveWorkSetMembers(_ members: [WorkSetMember], in windows: [WindowState]) -> [WorkSetResolvedMember] {
    var usedWindowIDs = Set<Int>()
    var resolved: [WorkSetResolvedMember] = []

    for member in members {
        if let match = matchingWorkSetWindow(for: member, in: windows, excluding: usedWindowIDs) {
            usedWindowIDs.insert(match.window.id)
            resolved.append(WorkSetResolvedMember(member: member, matchedWindow: match.window, status: match.status))
            continue
        }

        resolved.append(WorkSetResolvedMember(member: member, matchedWindow: nil, status: .missing))
    }

    return resolved
}

func resolveWorkSetMembersForScope(
    _ members: [WorkSetMember],
    visibleScopeWindows: [WindowState],
    allWindows: [WindowState],
    scopeKey: WorkSetScopeKey
) -> [WorkSetResolvedMember] {
    var usedWindowIDs = Set<Int>()
    var resolved: [WorkSetResolvedMember] = []

    for member in members {
        if let match = matchingWorkSetWindow(for: member, in: visibleScopeWindows, excluding: usedWindowIDs) {
            usedWindowIDs.insert(match.window.id)
            resolved.append(WorkSetResolvedMember(member: member, matchedWindow: match.window, status: match.status))
            continue
        }

        let scopeWindows = allWindows.filter {
            $0.display == scopeKey.displayID &&
            $0.space == scopeKey.spaceIndex
        }
        if let match = matchingWorkSetWindow(for: member, in: scopeWindows.filter(\.isMinimized), excluding: usedWindowIDs) {
            usedWindowIDs.insert(match.window.id)
            resolved.append(WorkSetResolvedMember(member: member, matchedWindow: match.window, status: .minimized))
            continue
        }

        let otherScopeWindows = allWindows.filter {
            $0.display != scopeKey.displayID ||
            $0.space != scopeKey.spaceIndex
        }
        if let match = matchingWorkSetWindow(for: member, in: otherScopeWindows, excluding: usedWindowIDs) {
            usedWindowIDs.insert(match.window.id)
            let status: WorkSetMemberMatchStatus = match.window.display == scopeKey.displayID
                ? .otherDesktop
                : .otherScreen
            resolved.append(WorkSetResolvedMember(member: member, matchedWindow: match.window, status: status))
            continue
        }

        resolved.append(WorkSetResolvedMember(member: member, matchedWindow: nil, status: .missing))
    }

    return resolved
}

private func matchingWorkSetWindow(
    for member: WorkSetMember,
    in windows: [WindowState],
    excluding usedWindowIDs: Set<Int>
) -> (window: WindowState, status: WorkSetMemberMatchStatus)? {
    if let exactMatch = windows.first(where: { window in
        !usedWindowIDs.contains(window.id) && workSetMember(member, exactlyMatches: window)
    }) {
        return (exactMatch, .exact)
    }

    if let titleRoleMatch = windows.first(where: { window in
        !usedWindowIDs.contains(window.id) && workSetMember(member, titleRoleMatches: window)
    }) {
        return (titleRoleMatch, .sameApp)
    }

    if let sameAppMatch = windows.first(where: { window in
        !usedWindowIDs.contains(window.id) && workSetMember(member, appMatches: window)
    }) {
        return (sameAppMatch, .sameApp)
    }

    return nil
}

private func workSetMember(_ member: WorkSetMember, appMatches window: WindowState) -> Bool {
    normalizedAppRuleKey(member.appName) == normalizedAppRuleKey(window.app)
}

private func workSetMember(_ member: WorkSetMember, exactlyMatches window: WindowState) -> Bool {
    guard let lastSeenWindowID = member.lastSeenWindowID,
          let lastSeenPID = member.lastSeenPID else {
        return false
    }
    return window.id == lastSeenWindowID && window.pid == lastSeenPID
}

private func workSetMember(_ member: WorkSetMember, titleRoleMatches window: WindowState) -> Bool {
    guard workSetMember(member, appMatches: window) else { return false }
    return normalizedWorkSetMetadata(member.windowTitle) == normalizedWorkSetMetadata(window.title)
        && normalizedWorkSetMetadata(member.role) == normalizedWorkSetMetadata(window.role)
        && normalizedWorkSetMetadata(member.subrole) == normalizedWorkSetMetadata(window.subrole)
}

private func normalizedWorkSetMetadata(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
}
