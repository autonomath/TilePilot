import AppKit
import CoreGraphics
import Foundation

struct LiveStatePollResult: Sendable {
    let timestamp: Date
    let yabaiDisplays: [DisplayState]?
    let yabaiSpaces: [SpaceState]?
    let yabaiWindows: [WindowState]?
    let fallbackDisplays: [FallbackDisplayCount]
    let yabaiWindowTotal: Int?
    let fallbackWindowTotal: Int?
    let errorMessage: String?
}

final class YabaiStateService: @unchecked Sendable {
    private let runner = CommandRunner()
    private var cachedFallbackDisplays: [FallbackDisplayCount] = []
    private var cachedFallbackUpdatedAt: Date?
    private var cachedScreenDescriptors: [ScreenDescriptor] = []
    private var cachedScreenDescriptorsUpdatedAt: Date?
    private let fallbackRefreshInterval: TimeInterval = 12
    private let screenDescriptorRefreshInterval: TimeInterval = 15

    private struct ScreenDescriptor: Sendable {
        let displayID: CGDirectDisplayID
        let uuid: String?
        let localizedName: String
        let frame: CGRect
    }

    private struct OnScreenWindowDescriptor: Sendable {
        let bounds: CGRect
        let title: String
        let orderIndex: Int
    }

    func pollLiveState() async -> LiveStatePollResult {
        async let displaysTask = runner.run(yabaiCommand(["-m", "query", "--displays"], timeout: 1.5))
        async let spacesTask = runner.run(yabaiCommand(["-m", "query", "--spaces"], timeout: 1.5))
        async let windowsTask = runner.run(yabaiCommand(["-m", "query", "--windows"], timeout: 1.5))

        let timestamp = Date()
        let displaysResult = await displaysTask
        let spacesResult = await spacesTask
        let windowsResult = await windowsTask
        let queriesSucceeded = displaysResult.isSuccess && spacesResult.isSuccess && windowsResult.isSuccess
        let fallbackDisplays = await cachedFallbackDisplayCounts(at: timestamp, forceRefresh: !queriesSucceeded)

        let fallbackTotal = fallbackDisplays.reduce(0) { $0 + $1.windowCount }

        guard queriesSucceeded else {
            let rawMessage = firstNonEmpty([
                windowsResult.stderr,
                spacesResult.stderr,
                displaysResult.stderr,
                windowsResult.stdout,
                spacesResult.stdout,
                displaysResult.stdout,
            ]) ?? "yabai query failed"
            let message = userFacingLiveStateError(from: rawMessage)

            return LiveStatePollResult(
                timestamp: timestamp,
                yabaiDisplays: nil,
                yabaiSpaces: nil,
                yabaiWindows: nil,
                fallbackDisplays: fallbackDisplays,
                yabaiWindowTotal: nil,
                fallbackWindowTotal: fallbackDisplays.isEmpty ? nil : fallbackTotal,
                errorMessage: trimForUI(message)
            )
        }

        do {
            let screenDescriptors = await cachedCurrentScreenDescriptors(at: timestamp)
            let onScreenWindowDescriptors = currentOnScreenWindowDescriptors()
            let parsed = try parseYabaiState(
                displaysJSON: displaysResult.stdout,
                spacesJSON: spacesResult.stdout,
                windowsJSON: windowsResult.stdout,
                timestamp: timestamp,
                screenDescriptors: screenDescriptors,
                onScreenWindowDescriptors: onScreenWindowDescriptors
            )

            return LiveStatePollResult(
                timestamp: timestamp,
                yabaiDisplays: parsed.displays,
                yabaiSpaces: parsed.spaces,
                yabaiWindows: parsed.windows,
                fallbackDisplays: fallbackDisplays,
                yabaiWindowTotal: parsed.windows.count,
                fallbackWindowTotal: fallbackDisplays.isEmpty ? nil : fallbackTotal,
                errorMessage: nil
            )
        } catch {
            return LiveStatePollResult(
                timestamp: timestamp,
                yabaiDisplays: nil,
                yabaiSpaces: nil,
                yabaiWindows: nil,
                fallbackDisplays: fallbackDisplays,
                yabaiWindowTotal: nil,
                fallbackWindowTotal: fallbackDisplays.isEmpty ? nil : fallbackTotal,
                errorMessage: trimForUI("Failed to parse yabai JSON: \(error.localizedDescription)")
            )
        }
    }

    private func cachedCurrentScreenDescriptors(at timestamp: Date) async -> [ScreenDescriptor] {
        if let updatedAt = cachedScreenDescriptorsUpdatedAt,
           timestamp.timeIntervalSince(updatedAt) < screenDescriptorRefreshInterval,
           !cachedScreenDescriptors.isEmpty {
            return cachedScreenDescriptors
        }

        let fresh = await currentScreenDescriptors()
        if !fresh.isEmpty {
            cachedScreenDescriptors = fresh
            cachedScreenDescriptorsUpdatedAt = timestamp
            return fresh
        }

        return cachedScreenDescriptors
    }

    private func cachedFallbackDisplayCounts(at timestamp: Date, forceRefresh: Bool) async -> [FallbackDisplayCount] {
        if !forceRefresh,
           let updatedAt = cachedFallbackUpdatedAt,
           timestamp.timeIntervalSince(updatedAt) < fallbackRefreshInterval,
           !cachedFallbackDisplays.isEmpty {
            return cachedFallbackDisplays
        }

        let fresh = await fallbackDisplayCounts()
        cachedFallbackUpdatedAt = timestamp

        if !fresh.isEmpty {
            cachedFallbackDisplays = fresh
            return fresh
        }

        return cachedFallbackDisplays
    }

    private func parseYabaiState(
        displaysJSON: String,
        spacesJSON: String,
        windowsJSON: String,
        timestamp: Date,
        screenDescriptors: [ScreenDescriptor],
        onScreenWindowDescriptors: [Int: OnScreenWindowDescriptor]
    ) throws -> (displays: [DisplayState], spaces: [SpaceState], windows: [WindowState]) {
        let displayRows = try jsonArray(from: displaysJSON)
        let spaceRows = try jsonArray(from: spacesJSON)
        let windowRows = try jsonArray(from: windowsJSON)

        let rawDisplays: [(id: Int, frame: CGRect)] = displayRows.compactMap { row in
            guard let id = int(from: row["index"]) ?? int(from: row["id"]) else {
                return nil
            }
            let frame = yabaiFrame(from: row["frame"]) ?? .zero
            return (id: id, frame: frame)
        }

        let windows: [WindowState] = windowRows.compactMap { row in
            guard let id = int(from: row["id"]),
                  let pid = int(from: row["pid"]),
                  let space = int(from: row["space"]),
                  let declaredDisplay = int(from: row["display"]) else {
                return nil
            }
            if isInternalTilePilotOverlayWindow(row) {
                return nil
            }
            let yabaiFrame = yabaiFrame(from: row["frame"]) ?? .zero
            let onScreenDescriptor = onScreenWindowDescriptors[id]
            let frame = preferredWindowFrame(
                forWindowID: id,
                yabaiFrame: yabaiFrame,
                onScreenWindowDescriptors: onScreenWindowDescriptors
            )
            let resolvedDisplay = bestDisplayID(for: frame, displays: rawDisplays) ?? declaredDisplay
            let rawTitle = string(from: row["title"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let role = string(from: row["role"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let subrole = string(from: row["subrole"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let effectiveTitle = preferredWindowTitle(
                yabaiTitle: rawTitle,
                onScreenWindowDescriptor: onScreenDescriptor
            )
            let effectiveVisibility = preferredWindowVisibility(
                yabaiVisible: bool(from: row["is-visible"]) ?? true,
                onScreenWindowDescriptor: onScreenDescriptor
            )

            return WindowState(
                id: id,
                pid: pid,
                app: string(from: row["app"]) ?? "Unknown",
                space: space,
                display: resolvedDisplay,
                frameX: frame.origin.x,
                frameY: frame.origin.y,
                frameW: frame.size.width,
                frameH: frame.size.height,
                floating: bool(from: row["is-floating"]) ?? false,
                hasAXReference: bool(from: row["has-ax-reference"]) ?? true,
                canMove: bool(from: row["can-move"]) ?? true,
                canResize: bool(from: row["can-resize"]) ?? true,
                title: effectiveTitle,
                role: role,
                subrole: subrole,
                focused: bool(from: row["has-focus"]) ?? false,
                isVisible: effectiveVisibility,
                isMinimized: bool(from: row["is-minimized"]) ?? false,
                isHidden: bool(from: row["is-hidden"]) ?? false,
                hasWindowServerMatch: onScreenDescriptor != nil,
                windowServerOrderIndex: onScreenDescriptor?.orderIndex,
                source: .yabai,
                lastUpdatedAt: timestamp
            )
        }
        .sorted { lhs, rhs in
            if lhs.display != rhs.display { return lhs.display < rhs.display }
            if lhs.space != rhs.space { return lhs.space < rhs.space }
            return lhs.id < rhs.id
        }

        let windowCountByDisplay = Dictionary(grouping: windows, by: \.display).mapValues(\.count)
        let windowCountBySpace = Dictionary(grouping: windows, by: \.space).mapValues(\.count)

        let spaces: [SpaceState] = spaceRows.compactMap { row in
            guard let index = int(from: row["index"]),
                  let display = int(from: row["display"]) else {
                return nil
            }
            let declaredWindowsCount = (row["windows"] as? [Any])?.count
            let effectiveCount = windowCountBySpace[index] ?? declaredWindowsCount ?? 0

            return SpaceState(
                index: index,
                label: string(from: row["label"]),
                displayId: display,
                focused: bool(from: row["has-focus"]) ?? false,
                visible: bool(from: row["is-visible"]) ?? false,
                layout: string(from: row["type"]),
                windowCount: effectiveCount,
                source: .yabai,
                lastUpdatedAt: timestamp
            )
        }
        .sorted { $0.index < $1.index }

        let displays: [DisplayState] = displayRows.compactMap { row in
            guard let id = int(from: row["index"]) ?? int(from: row["id"]) else {
                return nil
            }
            let name = resolvedDisplayName(from: row, fallbackID: id, screenDescriptors: screenDescriptors)
            let frame = yabaiFrame(from: row["frame"]) ?? .zero
            return DisplayState(
                id: id,
                name: name,
                frameX: frame.origin.x,
                frameY: frame.origin.y,
                frameW: frame.size.width,
                frameH: frame.size.height,
                focused: bool(from: row["has-focus"]) ?? false,
                windowCount: windowCountByDisplay[id] ?? 0,
                source: .yabai,
                lastUpdatedAt: timestamp
            )
        }
        .sorted { $0.id < $1.id }

        return (displays, spaces, windows)
    }

    private func isInternalTilePilotOverlayWindow(_ row: [String: Any]) -> Bool {
        let appName = string(from: row["app"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard appName == "tilepilot" else { return false }

        let hasAX = bool(from: row["has-ax-reference"]) ?? true
        let canMove = bool(from: row["can-move"]) ?? true
        let canResize = bool(from: row["can-resize"]) ?? true
        let title = string(from: row["title"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let role = string(from: row["role"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subrole = string(from: row["subrole"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Overlay helper panels are synthetic: no AX ref, immovable, non-resizable, untitled, no role/subrole.
        return !hasAX && !canMove && !canResize && title.isEmpty && role.isEmpty && subrole.isEmpty
    }

    private func resolvedDisplayName(
        from row: [String: Any],
        fallbackID: Int,
        screenDescriptors: [ScreenDescriptor]
    ) -> String {
        if let label = string(from: row["label"])?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }

        let yabaiUUID = string(from: row["uuid"])?.uppercased()
        if let yabaiUUID, let match = screenDescriptors.first(where: { $0.uuid?.uppercased() == yabaiUUID }) {
            return match.localizedName
        }

        if let frame = yabaiFrame(from: row["frame"]),
           let match = bestScreenDescriptor(for: frame, descriptors: screenDescriptors) {
            return match.localizedName
        }

        return "Display \(fallbackID)"
    }

    private func yabaiFrame(from value: Any?) -> CGRect? {
        guard let dict = value as? [String: Any] else { return nil }
        let x = double(from: dict["x"])
        let y = double(from: dict["y"])
        let w = double(from: dict["w"])
        let h = double(from: dict["h"])
        guard let x, let y, let w, let h else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func bestScreenDescriptor(for rect: CGRect, descriptors: [ScreenDescriptor]) -> ScreenDescriptor? {
        var best: ScreenDescriptor?
        var bestArea: CGFloat = 0
        for descriptor in descriptors {
            let intersection = rect.intersection(descriptor.frame)
            if intersection.isNull || intersection.isEmpty { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = descriptor
            }
        }
        return best
    }

    private func bestDisplayID(for rect: CGRect, displays: [(id: Int, frame: CGRect)]) -> Int? {
        var bestID: Int?
        var bestArea: CGFloat = 0

        for display in displays {
            let intersection = rect.intersection(display.frame)
            if intersection.isNull || intersection.isEmpty { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestID = display.id
            }
        }

        return bestID
    }

    private func jsonArray(from string: String) throws -> [[String: Any]] {
        let data = Data(string.utf8)
        let value = try JSONSerialization.jsonObject(with: data)
        guard let rows = value as? [[String: Any]] else {
            throw NSError(domain: "YabaiStateService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected JSON array"])
        }
        return rows
    }

    private func int(from value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func double(from value: Any?) -> Double? {
        switch value {
        case let d as Double:
            return d
        case let f as Float:
            return Double(f)
        case let i as Int:
            return Double(i)
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func bool(from value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.intValue != 0
        case let string as String:
            switch string.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    private func string(from value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func firstNonEmpty(_ values: [String]) -> String? {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func userFacingLiveStateError(from raw: String) -> String {
        let normalized = raw.lowercased()
        if normalized.contains("env: yabai: no such file or directory") || normalized.contains("not found") {
            return "TilePilot has not finished preparing its local yabai/skhd components yet. Run Guided Setup, then return to Overview."
        }
        if normalized.contains("could not connect")
            || normalized.contains("message socket")
            || normalized.contains("failed to connect to socket")
            || normalized.contains("socket unavailable") {
            return "TilePilot cannot talk to yabai yet. Run Guided Setup, start window control, and approve any yabai/skhd Accessibility prompt macOS shows."
        }
        if normalized.contains("permission") && normalized.contains("denied") {
            return "yabai was blocked by macOS permissions. Open Guided Setup, approve the exact yabai/skhd Accessibility entry macOS names, then retry."
        }
        return raw
    }

    private func currentScreenDescriptors() async -> [ScreenDescriptor] {
        await MainActor.run {
            NSScreen.screens.compactMap { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    return nil
                }
                let displayID = CGDirectDisplayID(number.uint32Value)
                let uuidString: String?
                if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
                    uuidString = (CFUUIDCreateString(nil, cfUUID) as String).uppercased()
                } else {
                    uuidString = nil
                }
                let name: String
                if #available(macOS 10.15, *) {
                    name = screen.localizedName
                } else {
                    name = "Display"
                }
                return ScreenDescriptor(
                    displayID: displayID,
                    uuid: uuidString,
                    localizedName: name,
                    frame: screen.frame
                )
            }
        }
    }

    private func fallbackDisplayCounts() async -> [FallbackDisplayCount] {
        await MainActor.run {
            let timestamp = Date()
            let screens = NSScreen.screens
            guard !screens.isEmpty else { return [] }

            let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

            var countsByScreenIndex = Array(repeating: 0, count: screens.count)

            for info in infoList {
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
                if layer != 0 { continue }

                let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
                if alpha <= 0.01 { continue }

                let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? ""
                if ownerName == "Window Server" || ownerName == "Control Center" {
                    continue
                }

                guard let boundsValue = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsValue) else {
                    continue
                }

                let area = bounds.width * bounds.height
                if area < 400 {
                    continue
                }

                guard let screenIndex = bestScreenIndex(for: bounds, screens: screens) else {
                    continue
                }
                countsByScreenIndex[screenIndex] += 1
            }

            return screens.enumerated().map { idx, screen in
                let name: String
                if #available(macOS 10.15, *) {
                    name = screen.localizedName
                } else {
                    name = "Display \(idx + 1)"
                }
                return FallbackDisplayCount(
                    id: "\(idx + 1)",
                    name: name,
                    windowCount: countsByScreenIndex[idx],
                    source: .fallback,
                    lastUpdatedAt: timestamp
                )
            }
        }
    }

    private func bestScreenIndex(for rect: CGRect, screens: [NSScreen]) -> Int? {
        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for (index, screen) in screens.enumerated() {
            let intersection = rect.intersection(screen.frame)
            if intersection.isNull || intersection.isEmpty { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func currentOnScreenWindowDescriptors() -> [Int: OnScreenWindowDescriptor] {
        let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard !infoList.isEmpty else { return [:] }

        var descriptors: [Int: OnScreenWindowDescriptor] = [:]
        for (orderIndex, info) in infoList.enumerated() {
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer != 0 { continue }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha <= 0.01 { continue }

            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let boundsValue = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsValue) else {
                continue
            }

            let area = bounds.width * bounds.height
            if area < 400 {
                continue
            }

            let title = (info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            descriptors[number] = OnScreenWindowDescriptor(
                bounds: bounds,
                title: title,
                orderIndex: orderIndex
            )
        }
        return descriptors
    }

    private func preferredWindowFrame(
        forWindowID id: Int,
        yabaiFrame: CGRect,
        onScreenWindowDescriptors: [Int: OnScreenWindowDescriptor]
    ) -> CGRect {
        onScreenWindowDescriptors[id]?.bounds ?? yabaiFrame
    }

    private func preferredWindowTitle(
        yabaiTitle: String,
        onScreenWindowDescriptor: OnScreenWindowDescriptor?
    ) -> String {
        guard yabaiTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return yabaiTitle
        }
        return onScreenWindowDescriptor?.title ?? ""
    }

    private func preferredWindowVisibility(
        yabaiVisible: Bool,
        onScreenWindowDescriptor: OnScreenWindowDescriptor?
    ) -> Bool {
        if onScreenWindowDescriptor != nil {
            return true
        }
        return yabaiVisible
    }
}
