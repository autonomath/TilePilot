import CoreGraphics
import Foundation

enum OverviewPreviewBuilder {
    static func build(
        snapshot: LiveStateSnapshot,
        isExcluded: (WindowState) -> Bool
    ) -> [OverviewDisplayPreview] {
        guard snapshot.source == .yabai, !snapshot.degraded else { return [] }

        let sortedDisplays = OverviewDisplayOrdering.verticallyOrdered(snapshot.displays)
        let windows = snapshot.windows.filter { window in
            !isExcluded(window)
        }
        let windowsBySpace = Dictionary(grouping: windows, by: \.space)
        let spacesByDisplay = Dictionary(grouping: snapshot.spaces, by: \.displayId)

        return sortedDisplays.compactMap { display in
            guard display.frameW > 1, display.frameH > 1 else { return nil }
            let desktops = (spacesByDisplay[display.id] ?? [])
                .sorted { $0.index < $1.index }
                .map { space in
                    let desktopIsFloating = (space.layout ?? "").lowercased() == "float"
                    let normalizedWindows = assignWarmPaletteIndices(
                        to: (windowsBySpace[space.index] ?? [])
                        .filter { $0.display == display.id }
                        .compactMap {
                            normalizedPreview(
                                for: $0,
                                in: display,
                                desktopIndex: space.index,
                                effectiveFloating: desktopIsFloating || $0.floating
                            )
                        }
                        .sorted { lhs, rhs in
                            if lhs.focused != rhs.focused { return lhs.focused && !rhs.focused }
                            return lhs.id < rhs.id
                        }
                    )
                    return OverviewDesktopPreview(
                        id: "display-\(display.id)-desktop-\(space.index)",
                        displayID: display.id,
                        desktopIndex: space.index,
                        focused: space.focused,
                        visible: space.visible,
                        tilingEnabled: (space.layout ?? "").lowercased() != "float",
                        windows: normalizedWindows
                    )
                }

            return OverviewDisplayPreview(
                id: display.id,
                name: display.name,
                focused: display.focused,
                aspectRatio: max(display.frameW, 1) / max(display.frameH, 1),
                frameW: display.frameW,
                frameH: display.frameH,
                desktops: desktops
            )
        }
    }

    static func normalizedPreview(for window: WindowState, in display: DisplayState, desktopIndex: Int) -> OverviewWindowPreview? {
        normalizedPreview(for: window, in: display, desktopIndex: desktopIndex, effectiveFloating: window.floating)
    }

    static func normalizedPreview(
        for window: WindowState,
        in display: DisplayState,
        desktopIndex: Int,
        effectiveFloating: Bool
    ) -> OverviewWindowPreview? {
        let displayW = max(display.frameW, 1)
        let displayH = max(display.frameH, 1)

        let x = (window.frameX - display.frameX) / displayW
        let y = (window.frameY - display.frameY) / displayH
        let w = window.frameW / displayW
        let h = window.frameH / displayH

        let left = max(0, min(1, x))
        let top = max(0, min(1, y))
        let right = max(0, min(1, x + w))
        let bottom = max(0, min(1, y + h))

        guard right > left, bottom > top else { return nil }

        return OverviewWindowPreview(
            id: window.id,
            app: window.app,
            title: window.title,
            desktopIndex: desktopIndex,
            floating: effectiveFloating,
            runtimeManageable: window.isRuntimeManageable,
            usesLimitedVisualStyle: window.usesLimitedVisualStyle,
            warmPaletteIndex: nil,
            focused: window.focused,
            visible: window.isVisible,
            normalizedX: left,
            normalizedY: top,
            normalizedW: right - left,
            normalizedH: bottom - top
        )
    }

    private static func assignWarmPaletteIndices(to windows: [OverviewWindowPreview]) -> [OverviewWindowPreview] {
        let warmIndices = windows.enumerated()
            .filter { _, window in
                window.floating || window.usesLimitedVisualStyle
            }
            .map(\.offset)

        guard !warmIndices.isEmpty else { return windows }

        let familyCount = MapWindowPalette.warmFamilyCount
        let maxSlot = max(familyCount - 1, 0)
        let divisor = max(warmIndices.count - 1, 1)

        return windows.enumerated().map { index, window in
            guard let warmPosition = warmIndices.firstIndex(of: index) else { return window }
            let paletteIndex = Int((Double(warmPosition) / Double(divisor) * Double(maxSlot)).rounded())
            return OverviewWindowPreview(
                id: window.id,
                app: window.app,
                title: window.title,
                desktopIndex: window.desktopIndex,
                floating: window.floating,
                runtimeManageable: window.runtimeManageable,
                usesLimitedVisualStyle: window.usesLimitedVisualStyle,
                warmPaletteIndex: paletteIndex,
                focused: window.focused,
                visible: window.visible,
                normalizedX: window.normalizedX,
                normalizedY: window.normalizedY,
                normalizedW: window.normalizedW,
                normalizedH: window.normalizedH
            )
        }
    }
}

enum OverviewDisplayOrdering {
    static func verticallyOrdered(_ displays: [DisplayState]) -> [DisplayState] {
        displays.sorted(by: verticalSort)
    }

    // For now the Overview only preserves above/below placement. Displays in the same
    // vertical band still fall back to focus/id ordering because left/right layout is unsupported.
    private static func verticalSort(_ lhs: DisplayState, _ rhs: DisplayState) -> Bool {
        let lhsMidY = lhs.frameY + (lhs.frameH / 2)
        let rhsMidY = rhs.frameY + (rhs.frameH / 2)
        let tolerance = max(40, min(lhs.frameH, rhs.frameH) * 0.18)

        if abs(lhsMidY - rhsMidY) > tolerance {
            return lhsMidY < rhsMidY
        }
        if lhs.focused != rhs.focused {
            return lhs.focused && !rhs.focused
        }
        return lhs.id < rhs.id
    }
}

enum OverviewMiniMapGeometry {
    static func frame(for window: OverviewWindowPreview, in canvasSize: CGSize) -> CGRect {
        let x = max(0, min(1, window.normalizedX)) * canvasSize.width
        let y = max(0, min(1, window.normalizedY)) * canvasSize.height
        let maxWidth = max(0, canvasSize.width - x)
        let maxHeight = max(0, canvasSize.height - y)
        let width = min(maxWidth, max(10, window.normalizedW * canvasSize.width))
        let height = min(maxHeight, max(8, window.normalizedH * canvasSize.height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func iconFrame(
        for window: OverviewWindowPreview,
        iconSize: CGFloat,
        inset: CGFloat,
        in canvasSize: CGSize
    ) -> CGRect {
        let windowFrame = frame(for: window, in: canvasSize)
        let availableWidth = max(0, windowFrame.width - (inset * 2))
        let availableHeight = max(0, windowFrame.height - (inset * 2))
        let width = min(iconSize, availableWidth)
        let height = min(iconSize, availableHeight)
        return CGRect(
            x: windowFrame.minX + inset,
            y: windowFrame.minY + inset,
            width: width,
            height: height
        )
    }
}
