import Foundation

enum MegamapDesktopContentMode: String, Sendable, Equatable {
    case screenshot
    case syntheticFallback
    case unavailable
}

struct MegamapCaptureRecord: Sendable, Equatable {
    let displayID: Int
    let displayName: String
    let displayAspectRatio: Double
    let desktopIndex: Int
    let capturedFrameX: Double
    let capturedFrameY: Double
    let capturedFrameW: Double
    let capturedFrameH: Double
    let screenshotPath: String
    let capturedAt: Date
}

struct MegamapCaptureProgress: Sendable, Equatable {
    let completed: Int
    let total: Int
    let currentDesktopIndex: Int?

    var summary: String {
        guard let currentDesktopIndex else {
            return "Captured \(completed) of \(total)"
        }
        return "Capturing Desktop \(currentDesktopIndex) (\(completed + 1) of \(total))"
    }
}

struct MegamapDesktopSection: Identifiable, Sendable, Equatable {
    let id: String
    let displayID: Int
    let displayName: String
    let displayAspectRatio: Double
    let displayFrameX: Double
    let displayFrameY: Double
    let displayFrameW: Double
    let displayFrameH: Double
    let desktopIndex: Int
    let focused: Bool
    let visible: Bool
    let tilingEnabled: Bool?
    let contentMode: MegamapDesktopContentMode
    let screenshotPath: String?
    let screenshotCropX: Double
    let screenshotCropY: Double
    let screenshotCropW: Double
    let screenshotCropH: Double
    let capturedAt: Date?
    let fallbackPreview: OverviewDesktopPreview?
    let message: String?
}

struct MegamapDisplaySection: Identifiable, Sendable, Equatable {
    let id: Int
    let name: String
    let focused: Bool
    let desktops: [MegamapDesktopSection]
}
