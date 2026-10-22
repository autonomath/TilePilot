import CoreGraphics
import Foundation

/// Where the System Bar sits relative to a Work Area, and the part left for windows.
struct SystemBarLayout: Equatable, Sendable {
    let bar: CGRect
    let windowArea: CGRect
    let isAboveWorkArea: Bool
}

/// Pure Work Area math. All rectangles use yabai's top-left screen coordinates unless a
/// function name says otherwise.
enum WorkAreaGeometry {
    static let containmentTolerance: CGFloat = 2
    static let fallbackMenuBarHeight: CGFloat = 24

    /// Keeps a normalized rectangle inside 0...1 and, when the display size is known, at least
    /// `WorkAreaConfiguration.minimumSize` points large.
    static func clampedNormalizedRect(
        _ rect: CGRect,
        displaySize: CGSize?,
        minimumSize: CGSize = WorkAreaConfiguration.minimumSize
    ) -> CGRect {
        var minWidth: CGFloat = 0.05
        var minHeight: CGFloat = 0.05
        if let displaySize, displaySize.width > 1, displaySize.height > 1 {
            minWidth = min(1, minimumSize.width / displaySize.width)
            minHeight = min(1, minimumSize.height / displaySize.height)
        }
        let finite: (CGFloat, CGFloat) -> CGFloat = { value, fallback in
            value.isFinite ? value : fallback
        }
        let width = min(1, max(minWidth, finite(rect.width, 1)))
        let height = min(1, max(minHeight, finite(rect.height, 1)))
        let x = min(max(0, finite(rect.minX, 0)), 1 - width)
        let y = min(max(0, finite(rect.minY, 0)), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Builds a normalized rectangle with the given point size, centered horizontally and placed
    /// vertically by the preset.
    static func normalizedRect(
        size: CGSize,
        position: WorkAreaPositionPreset,
        displaySize: CGSize
    ) -> CGRect {
        guard displaySize.width > 1, displaySize.height > 1 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let width = min(1, max(0, size.width / displaySize.width))
        let height = min(1, max(0, size.height / displaySize.height))
        let rect = CGRect(
            x: (1 - width) / 2,
            y: (1 - height) * position.verticalFactor,
            width: width,
            height: height
        )
        return clampedNormalizedRect(rect, displaySize: displaySize)
    }

    /// The first-time suggestion: 2560 × 1440 when it fits comfortably, otherwise 80% of the display,
    /// placed in the lower center.
    static func suggestedNormalizedRect(displaySize: CGSize) -> CGRect {
        let width = min(2560, (displaySize.width * 0.8).rounded())
        let height = min(1440, (displaySize.height * 0.8).rounded())
        return normalizedRect(
            size: CGSize(width: width, height: height),
            position: .lowerCenter,
            displaySize: displaySize
        )
    }

    static func absoluteRect(normalized: CGRect, displayFrame: CGRect) -> CGRect {
        CGRect(
            x: displayFrame.minX + normalized.minX * displayFrame.width,
            y: displayFrame.minY + normalized.minY * displayFrame.height,
            width: normalized.width * displayFrame.width,
            height: normalized.height * displayFrame.height
        )
    }

    static func normalizedRect(absolute: CGRect, displayFrame: CGRect) -> CGRect {
        guard displayFrame.width > 1, displayFrame.height > 1 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(
            x: (absolute.minX - displayFrame.minX) / displayFrame.width,
            y: (absolute.minY - displayFrame.minY) / displayFrame.height,
            width: absolute.width / displayFrame.width,
            height: absolute.height / displayFrame.height
        )
    }

    /// The effective Work Area in points: the saved rectangle limited to the part of the display
    /// that the menu bar and Dock leave free, never smaller than the minimum size when the free
    /// area allows it.
    static func resolve(
        normalizedRect: CGRect,
        displayFrame: CGRect,
        visibleFrame: CGRect?,
        minimumSize: CGSize = WorkAreaConfiguration.minimumSize
    ) -> CGRect {
        let usable: CGRect = {
            guard let visibleFrame, !visibleFrame.isNull, !visibleFrame.isEmpty else { return displayFrame }
            let intersection = displayFrame.intersection(visibleFrame)
            return intersection.isNull || intersection.isEmpty ? displayFrame : intersection
        }()
        let requested = absoluteRect(normalized: normalizedRect, displayFrame: displayFrame)
        var area = requested.intersection(usable)
        if area.isNull || area.isEmpty {
            area = usable
        }

        let minWidth = min(minimumSize.width, usable.width)
        let minHeight = min(minimumSize.height, usable.height)
        if area.width < minWidth {
            let grow = minWidth - area.width
            area.origin.x -= grow / 2
            area.size.width = minWidth
        }
        if area.height < minHeight {
            let grow = minHeight - area.height
            area.origin.y -= grow / 2
            area.size.height = minHeight
        }
        area.origin.x = min(max(area.minX, usable.minX), usable.maxX - area.width)
        area.origin.y = min(max(area.minY, usable.minY), usable.maxY - area.height)
        return roundedInward(area)
    }

    /// Per-side yabai padding that keeps tiled windows inside the Work Area. yabai lays tiles out
    /// inside the visible frame, so the inset is measured from there, then Screen Edge Padding is
    /// added inside the Work Area.
    static func yabaiPadding(workArea: CGRect, visibleFrame: CGRect, outerPadding: Int) -> WorkAreaPadding {
        let extra = max(0, outerPadding)
        func inset(_ value: CGFloat) -> Int {
            max(0, Int(value.rounded())) + extra
        }
        return WorkAreaPadding(
            top: inset(workArea.minY - visibleFrame.minY),
            bottom: inset(visibleFrame.maxY - workArea.maxY),
            left: inset(workArea.minX - visibleFrame.minX),
            right: inset(visibleFrame.maxX - workArea.maxX)
        )
    }

    static func isContained(_ frame: CGRect, in workArea: CGRect, tolerance: CGFloat = containmentTolerance) -> Bool {
        frame.minX >= workArea.minX - tolerance &&
            frame.minY >= workArea.minY - tolerance &&
            frame.maxX <= workArea.maxX + tolerance &&
            frame.maxY <= workArea.maxY + tolerance
    }

    /// Where a window should go to sit fully inside the Work Area, or nil when it already does.
    /// Oversized windows shrink to fit (unless they cannot resize, and never below `minimumSize`),
    /// then move the shortest distance. Small windows keep their size.
    static func containedFrame(
        windowFrame: CGRect,
        workArea: CGRect,
        canResize: Bool = true,
        minimumSize: CGSize = CGSize(width: 80, height: 60)
    ) -> CGRect? {
        guard !windowFrame.isEmpty, !workArea.isEmpty else { return nil }
        guard !isContained(windowFrame, in: workArea) else { return nil }

        var width = windowFrame.width
        var height = windowFrame.height
        if canResize {
            width = max(min(width, workArea.width), min(width, minimumSize.width))
            height = max(min(height, workArea.height), min(height, minimumSize.height))
        }

        let x = width > workArea.width
            ? workArea.minX
            : min(max(windowFrame.minX, workArea.minX), workArea.maxX - width)
        let y = height > workArea.height
            ? workArea.minY
            : min(max(windowFrame.minY, workArea.minY), workArea.maxY - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(.down), height: height.rounded(.down))
    }

    static func fillFrame(workArea: CGRect) -> CGRect {
        workArea
    }

    /// Mission Control, App Exposé, and Show Desktop move and scale what the window server reports
    /// for every window, while Accessibility keeps each window's real frame. A size change or a jump
    /// of more than 120 pt counts. One window that disagrees could be an app quirk, so when several
    /// windows are compared at least two must disagree.
    static func windowServerLooksTransformed(_ samples: [(windowServer: CGRect, accessibility: CGRect)]) -> Bool {
        let transformed = samples.filter { sample in
            abs(sample.windowServer.width - sample.accessibility.width) > 6 ||
                abs(sample.windowServer.height - sample.accessibility.height) > 6 ||
                abs(sample.windowServer.minX - sample.accessibility.minX) > 120 ||
                abs(sample.windowServer.minY - sample.accessibility.minY) > 120
        }.count
        return samples.count == 1 ? transformed == 1 : transformed >= 2
    }

    /// Puts the System Bar directly above the Work Area when the menu bar and Dock leave room,
    /// otherwise inside its top edge, where it takes height away from the window area.
    static func systemBarLayout(workArea: CGRect, visibleFrame: CGRect, barHeight: CGFloat) -> SystemBarLayout {
        let height = max(1, barHeight.rounded())
        if workArea.minY - visibleFrame.minY >= height {
            let bar = CGRect(x: workArea.minX, y: workArea.minY - height, width: workArea.width, height: height)
            return SystemBarLayout(bar: bar, windowArea: workArea, isAboveWorkArea: true)
        }
        let bar = CGRect(x: workArea.minX, y: workArea.minY, width: workArea.width, height: height)
        let windowArea = CGRect(
            x: workArea.minX,
            y: workArea.minY + height,
            width: workArea.width,
            height: max(0, workArea.height - height)
        )
        return SystemBarLayout(bar: bar, windowArea: windowArea, isAboveWorkArea: false)
    }

    /// Converts an AppKit rectangle (bottom-left origin) into yabai's top-left coordinates, using
    /// the top edge of the primary screen as the reference.
    static func topLeftRect(fromAppKit rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The inverse of `topLeftRect`: yabai's top-left coordinates back to AppKit's bottom-left.
    static func appKitRect(fromTopLeft rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func roundedInward(_ rect: CGRect) -> CGRect {
        // Values a hair away from a whole point come from fraction math; snap those instead of
        // losing a full point.
        func inward(_ value: CGFloat, up: Bool) -> CGFloat {
            let nearest = value.rounded()
            if abs(value - nearest) < 0.01 { return nearest }
            return up ? value.rounded(.up) : value.rounded(.down)
        }
        let minX = inward(rect.minX, up: true)
        let minY = inward(rect.minY, up: true)
        let maxX = inward(rect.maxX, up: false)
        let maxY = inward(rect.maxY, up: false)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}
