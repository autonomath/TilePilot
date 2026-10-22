import CoreGraphics
import Foundation

/// One saved Work Area: a smaller rectangle on a single display where TilePilot keeps windows.
/// The rectangle is stored as fractions of the display frame (top-left origin) so it scales
/// with display resolution changes.
struct WorkAreaConfiguration: Codable, Hashable, Sendable, Identifiable {
    static let minimumSize = CGSize(width: 640, height: 400)

    var displayUUID: String?
    var displayName: String
    var displayWidth: Double
    var displayHeight: Double
    var enabled: Bool
    var normalizedX: Double
    var normalizedY: Double
    var normalizedWidth: Double
    var normalizedHeight: Double
    var containmentEnabled: Bool
    var excludedApps: [String]
    /// Mirror the menu bar (app menus and icons) at the top of the Work Area.
    var systemBarEnabled: Bool
    /// Mirror notification banners inside the Work Area (not implemented yet; reserved).
    var notificationMirrorEnabled: Bool
    /// Open menu bar icon panels inside the Work Area (not implemented yet; reserved).
    var panelMirrorEnabled: Bool

    var id: String {
        if let displayUUID, !displayUUID.isEmpty {
            return displayUUID.uppercased()
        }
        return "size-\(Int(displayWidth.rounded()))x\(Int(displayHeight.rounded()))-\(displayName)"
    }

    var normalizedRect: CGRect {
        get {
            CGRect(x: normalizedX, y: normalizedY, width: normalizedWidth, height: normalizedHeight)
        }
        set {
            normalizedX = newValue.minX
            normalizedY = newValue.minY
            normalizedWidth = newValue.width
            normalizedHeight = newValue.height
        }
    }

    init(
        displayUUID: String?,
        displayName: String,
        displayWidth: Double,
        displayHeight: Double,
        enabled: Bool = true,
        normalizedRect: CGRect,
        containmentEnabled: Bool = true,
        excludedApps: [String] = [],
        systemBarEnabled: Bool = false,
        notificationMirrorEnabled: Bool = false,
        panelMirrorEnabled: Bool = true
    ) {
        self.displayUUID = displayUUID?.uppercased()
        self.displayName = displayName
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.enabled = enabled
        self.normalizedX = normalizedRect.minX
        self.normalizedY = normalizedRect.minY
        self.normalizedWidth = normalizedRect.width
        self.normalizedHeight = normalizedRect.height
        self.containmentEnabled = containmentEnabled
        self.excludedApps = excludedApps
        self.systemBarEnabled = systemBarEnabled
        self.notificationMirrorEnabled = notificationMirrorEnabled
        self.panelMirrorEnabled = panelMirrorEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case displayUUID
        case displayName
        case displayWidth
        case displayHeight
        case enabled
        case normalizedX
        case normalizedY
        case normalizedWidth
        case normalizedHeight
        case containmentEnabled
        case excludedApps
        case systemBarEnabled
        case notificationMirrorEnabled
        case panelMirrorEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayUUID = try container.decodeIfPresent(String.self, forKey: .displayUUID)?.uppercased()
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? "Display"
        displayWidth = try container.decodeIfPresent(Double.self, forKey: .displayWidth) ?? 0
        displayHeight = try container.decodeIfPresent(Double.self, forKey: .displayHeight) ?? 0
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let rect = WorkAreaGeometry.clampedNormalizedRect(
            CGRect(
                x: try container.decodeIfPresent(Double.self, forKey: .normalizedX) ?? 0,
                y: try container.decodeIfPresent(Double.self, forKey: .normalizedY) ?? 0,
                width: try container.decodeIfPresent(Double.self, forKey: .normalizedWidth) ?? 1,
                height: try container.decodeIfPresent(Double.self, forKey: .normalizedHeight) ?? 1
            ),
            displaySize: nil
        )
        normalizedX = rect.minX
        normalizedY = rect.minY
        normalizedWidth = rect.width
        normalizedHeight = rect.height
        containmentEnabled = try container.decodeIfPresent(Bool.self, forKey: .containmentEnabled) ?? true
        excludedApps = try container.decodeIfPresent([String].self, forKey: .excludedApps) ?? []
        systemBarEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemBarEnabled) ?? false
        notificationMirrorEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationMirrorEnabled) ?? false
        panelMirrorEnabled = try container.decodeIfPresent(Bool.self, forKey: .panelMirrorEnabled) ?? true
    }

    func excludesApp(_ appName: String) -> Bool {
        let key = normalizedAppRuleKey(appName)
        guard !key.isEmpty else { return false }
        return excludedApps.contains { normalizedAppRuleKey($0) == key }
    }

    /// Finds the saved Work Area for a connected display. A UUID match wins. When the UUID changed
    /// (for example after moving the monitor to another port), an orphaned configuration with the
    /// same display size takes over, preferring one with the same display name.
    static func matchIndex(
        displayUUID: String?,
        displayName: String,
        width: Double,
        height: Double,
        connectedUUIDs: Set<String>,
        in configurations: [WorkAreaConfiguration]
    ) -> Int? {
        let wantedUUID = displayUUID?.uppercased()
        if let wantedUUID, !wantedUUID.isEmpty,
           let index = configurations.firstIndex(where: { $0.displayUUID == wantedUUID }) {
            return index
        }

        let connected = Set(connectedUUIDs.map { $0.uppercased() })
        let orphanedSameSize = configurations.indices.filter { index in
            let configuration = configurations[index]
            if let savedUUID = configuration.displayUUID, connected.contains(savedUUID) {
                return false
            }
            return abs(configuration.displayWidth - width) <= 1 && abs(configuration.displayHeight - height) <= 1
        }
        if let sameName = orphanedSameSize.first(where: { configurations[$0].displayName == displayName }) {
            return sameName
        }
        return orphanedSameSize.first
    }
}

enum WorkAreaPositionPreset: String, CaseIterable, Identifiable, Sendable {
    case center
    case lowerCenter
    case bottomCenter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .center: return "Center"
        case .lowerCenter: return "Lower center"
        case .bottomCenter: return "Bottom center"
        }
    }

    /// Share of the free vertical space placed above the Work Area.
    var verticalFactor: Double {
        switch self {
        case .center: return 0.5
        case .lowerCenter: return 0.75
        case .bottomCenter: return 1.0
        }
    }
}

enum WorkAreaSizePreset: String, CaseIterable, Identifiable, Sendable {
    case qhd
    case qhdPlus
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qhd: return "2560 × 1440"
        case .qhdPlus: return "3200 × 1800"
        case .full: return "Full"
        }
    }

    func size(for displaySize: CGSize) -> CGSize {
        switch self {
        case .qhd:
            return CGSize(width: min(2560, displaySize.width), height: min(1440, displaySize.height))
        case .qhdPlus:
            return CGSize(width: min(3200, displaySize.width), height: min(1800, displaySize.height))
        case .full:
            return displaySize
        }
    }
}

struct WorkAreaPadding: Equatable, Hashable, Sendable {
    let top: Int
    let bottom: Int
    let left: Int
    let right: Int

    static func uniform(_ value: Int) -> WorkAreaPadding {
        let clamped = max(0, value)
        return WorkAreaPadding(top: clamped, bottom: clamped, left: clamped, right: clamped)
    }
}

struct WorkAreaUnfitWindow: Identifiable, Equatable, Sendable {
    let windowID: Int
    let app: String
    let title: String
    let displayID: Int

    var id: Int { windowID }
}

struct WorkAreaFitBatch: Equatable, Sendable {
    let createdAt: Date
    let previousFramesByWindowID: [Int: CGRect]
}
