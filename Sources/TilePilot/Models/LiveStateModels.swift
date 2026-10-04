import CoreGraphics
import Foundation

enum StateSourceQuality: String, Codable, Sendable {
    case yabai
    case fallback
    case stale
}

struct DisplayState: Identifiable, Codable, Sendable, Equatable {
    let id: Int
    let name: String
    let frameX: Double
    let frameY: Double
    let frameW: Double
    let frameH: Double
    let focused: Bool
    let windowCount: Int
    let source: StateSourceQuality
    let lastUpdatedAt: Date
}

struct SpaceState: Identifiable, Codable, Sendable, Equatable {
    let index: Int
    let label: String?
    let displayId: Int
    let focused: Bool
    let visible: Bool
    let layout: String?
    let windowCount: Int
    let source: StateSourceQuality
    let lastUpdatedAt: Date

    var id: Int { index }
}

struct WindowState: Identifiable, Codable, Sendable, Equatable {
    let id: Int
    let pid: Int
    let app: String
    let space: Int
    let display: Int
    let frameX: Double
    let frameY: Double
    let frameW: Double
    let frameH: Double
    let floating: Bool
    let hasAXReference: Bool
    let canMove: Bool
    let canResize: Bool
    let title: String
    let role: String
    let subrole: String
    let focused: Bool
    let isVisible: Bool
    let isMinimized: Bool
    let isHidden: Bool
    let hasWindowServerMatch: Bool
    let windowServerOrderIndex: Int?
    let source: StateSourceQuality
    let lastUpdatedAt: Date

    var supportsFocusedFloatToggleFallback: Bool {
        (app == "iTerm2" || app == "iTerm") && !isMinimized && !isHidden
    }

    var isRuntimeManageable: Bool {
        (hasAXReference && canMove) || supportsFocusedFloatToggleFallback
    }

    var usesLimitedVisualStyle: Bool {
        !isRuntimeManageable
    }


    private enum CodingKeys: String, CodingKey {
        case id
        case pid
        case app
        case space
        case display
        case frameX
        case frameY
        case frameW
        case frameH
        case floating
        case hasAXReference
        case canMove
        case canResize
        case title
        case role
        case subrole
        case focused
        case isVisible
        case isMinimized
        case isHidden
        case hasWindowServerMatch
        case windowServerOrderIndex
        case source
        case lastUpdatedAt
    }

    init(
        id: Int,
        pid: Int,
        app: String,
        space: Int,
        display: Int,
        frameX: Double,
        frameY: Double,
        frameW: Double,
        frameH: Double,
        floating: Bool,
        hasAXReference: Bool,
        canMove: Bool,
        canResize: Bool,
        title: String,
        role: String = "",
        subrole: String = "",
        focused: Bool,
        isVisible: Bool,
        isMinimized: Bool,
        isHidden: Bool,
        hasWindowServerMatch: Bool = false,
        windowServerOrderIndex: Int? = nil,
        source: StateSourceQuality,
        lastUpdatedAt: Date
    ) {
        self.id = id
        self.pid = pid
        self.app = app
        self.space = space
        self.display = display
        self.frameX = frameX
        self.frameY = frameY
        self.frameW = frameW
        self.frameH = frameH
        self.floating = floating
        self.hasAXReference = hasAXReference
        self.canMove = canMove
        self.canResize = canResize
        self.title = title
        self.role = role
        self.subrole = subrole
        self.focused = focused
        self.isVisible = isVisible
        self.isMinimized = isMinimized
        self.isHidden = isHidden
        self.hasWindowServerMatch = hasWindowServerMatch
        self.windowServerOrderIndex = windowServerOrderIndex
        self.source = source
        self.lastUpdatedAt = lastUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        pid = try container.decode(Int.self, forKey: .pid)
        app = try container.decode(String.self, forKey: .app)
        space = try container.decode(Int.self, forKey: .space)
        display = try container.decode(Int.self, forKey: .display)
        frameX = try container.decode(Double.self, forKey: .frameX)
        frameY = try container.decode(Double.self, forKey: .frameY)
        frameW = try container.decode(Double.self, forKey: .frameW)
        frameH = try container.decode(Double.self, forKey: .frameH)
        floating = try container.decode(Bool.self, forKey: .floating)
        hasAXReference = try container.decode(Bool.self, forKey: .hasAXReference)
        canMove = try container.decode(Bool.self, forKey: .canMove)
        canResize = try container.decode(Bool.self, forKey: .canResize)
        title = try container.decode(String.self, forKey: .title)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        subrole = try container.decodeIfPresent(String.self, forKey: .subrole) ?? ""
        focused = try container.decode(Bool.self, forKey: .focused)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        isMinimized = try container.decode(Bool.self, forKey: .isMinimized)
        isHidden = try container.decode(Bool.self, forKey: .isHidden)
        hasWindowServerMatch = try container.decodeIfPresent(Bool.self, forKey: .hasWindowServerMatch) ?? false
        windowServerOrderIndex = try container.decodeIfPresent(Int.self, forKey: .windowServerOrderIndex)
        source = try container.decode(StateSourceQuality.self, forKey: .source)
        lastUpdatedAt = try container.decode(Date.self, forKey: .lastUpdatedAt)
    }
}

enum WindowBadgeVisibilityMode: String, Codable, CaseIterable, Sendable {
    case focusedAndHovered
    case alwaysOn
    case focusedOnly
}

struct WindowBadgeState: Identifiable, Sendable, Equatable {
    let windowID: Int
    let pid: Int
    let app: String
    let title: String
    let isFloating: Bool
    let isFocused: Bool
    let isRuntimeManageable: Bool
    let usesLimitedVisualStyle: Bool
    let frameX: Double
    let frameY: Double
    let frameW: Double
    let frameH: Double

    var id: Int { windowID }

    var frame: CGRect {
        CGRect(x: frameX, y: frameY, width: frameW, height: frameH)
    }
}

struct FallbackDisplayCount: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let name: String
    let windowCount: Int
    let source: StateSourceQuality
    let lastUpdatedAt: Date
}

struct LiveStateSnapshot: Codable, Sendable, Equatable {
    let displays: [DisplayState]
    let spaces: [SpaceState]
    let windows: [WindowState]
    let fallbackDisplays: [FallbackDisplayCount]
    let source: StateSourceQuality
    let lastUpdatedAt: Date
    let degraded: Bool
    let degradedReason: String?
    let yabaiWindowTotal: Int?
    let fallbackWindowTotal: Int?
    let consecutiveMismatchSamples: Int
    let consecutiveHealthySamples: Int
    let lastErrorMessage: String?
}

struct OverviewDisplayPreview: Identifiable, Sendable, Equatable {
    let id: Int
    let name: String
    let focused: Bool
    let aspectRatio: Double
    let frameW: Double
    let frameH: Double
    let desktops: [OverviewDesktopPreview]
}

struct OverviewDesktopPreview: Identifiable, Sendable, Equatable {
    let id: String
    let displayID: Int
    let desktopIndex: Int
    let focused: Bool
    let visible: Bool
    let tilingEnabled: Bool
    let windows: [OverviewWindowPreview]
}

struct OverviewWindowPreview: Identifiable, Sendable, Equatable {
    let id: Int
    let app: String
    let title: String
    let desktopIndex: Int
    let floating: Bool
    let runtimeManageable: Bool
    let usesLimitedVisualStyle: Bool
    let warmPaletteIndex: Int?
    let focused: Bool
    let visible: Bool
    let normalizedX: Double
    let normalizedY: Double
    let normalizedW: Double
    let normalizedH: Double
}

struct OverviewDisplaySection: Identifiable, Sendable, Equatable {
    let id: Int
    let display: DisplayState
    let visibleWindowCount: Int
    let totalWindowCount: Int
    let spaces: [OverviewSpaceSection]
}

struct OverviewSpaceSection: Identifiable, Sendable, Equatable {
    let id: Int
    let space: SpaceState
    let tilingEnabled: Bool
    let visibleWindowCount: Int
    let totalWindowCount: Int
    let windows: [WindowState]
}

struct RuntimeDiagnostics: Sendable, Equatable {
    var liveStateRefreshCount: Int = 0
    var liveStatePublishedCount: Int = 0
    var liveStateUnchangedPollCount: Int = 0
    var overviewCacheRebuildCount: Int = 0
    var shortcutsCacheRebuildCount: Int = 0
    var keepOnTopEnforcementPassCount: Int = 0
    var miniMapHoverUpdateCount: Int = 0
    var overlayPanelUpdateCount: Int = 0
    var runtimeActivityMode: String = "Idle"
    var currentPollingIntervalSeconds: Double = 0
    var currentKeepOnTopIntervalSeconds: Double = 0
    var performanceMode: String = "Full"
    var performanceModeDetail: String = ""
    var recentLiveStateRefreshCount: Int = 0
    var recentLiveStatePublishedCount: Int = 0
    var recentLiveStateUnchangedPollCount: Int = 0
    var recentOverviewCacheRebuildCount: Int = 0
    var recentShortcutsCacheRebuildCount: Int = 0
    var recentKeepOnTopEnforcementPassCount: Int = 0
    var recentOverlayPanelUpdateCount: Int = 0
    var dominantBurstSource: String = "Idle"
    var megamapRefreshCount: Int = 0
    var megamapFirstSwitchLatencyMilliseconds: Double = 0
    var megamapAverageSwitchVerificationMilliseconds: Double = 0
    var megamapAverageCaptureMilliseconds: Double = 0
    var megamapTotalSweepMilliseconds: Double = 0
    var megamapCapturedDesktopCount: Int = 0
    var megamapFailedDesktopCount: Int = 0
}
