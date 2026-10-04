import SwiftUI

struct MapWindowPaletteColors {
    let border: Color
    let fill: Color
}

enum MapWindowPalette {
    private struct WarmFamily {
        let floatingBorder: Color
        let floatingFill: Color
        let limitedBorder: Color
        let limitedFill: Color
    }

    private static let tiledBorder = Color(red: 0.20, green: 0.50, blue: 0.95)
    private static let tiledFocusedBorder = Color(red: 0.32, green: 0.66, blue: 1.0)

    // Keep the floating-window palette warm and varied, but stop before red.
    // In TilePilot, red already reads as an error/problem state elsewhere in the UI.
    private static let warmFamilies: [WarmFamily] = [
        WarmFamily(
            floatingBorder: Color(red: 0.96, green: 0.83, blue: 0.37),
            floatingFill: Color(red: 0.96, green: 0.83, blue: 0.37, opacity: 0.14),
            limitedBorder: Color(red: 0.78, green: 0.70, blue: 0.48),
            limitedFill: Color(red: 0.78, green: 0.70, blue: 0.48, opacity: 0.11)
        ),
        WarmFamily(
            floatingBorder: Color(red: 0.95, green: 0.76, blue: 0.31),
            floatingFill: Color(red: 0.95, green: 0.76, blue: 0.31, opacity: 0.14),
            limitedBorder: Color(red: 0.77, green: 0.65, blue: 0.42),
            limitedFill: Color(red: 0.77, green: 0.65, blue: 0.42, opacity: 0.11)
        ),
        WarmFamily(
            floatingBorder: Color(red: 0.93, green: 0.69, blue: 0.29),
            floatingFill: Color(red: 0.93, green: 0.69, blue: 0.29, opacity: 0.14),
            limitedBorder: Color(red: 0.75, green: 0.60, blue: 0.37),
            limitedFill: Color(red: 0.75, green: 0.60, blue: 0.37, opacity: 0.11)
        ),
        WarmFamily(
            floatingBorder: Color(red: 0.91, green: 0.61, blue: 0.27),
            floatingFill: Color(red: 0.91, green: 0.61, blue: 0.27, opacity: 0.14),
            limitedBorder: Color(red: 0.72, green: 0.54, blue: 0.34),
            limitedFill: Color(red: 0.72, green: 0.54, blue: 0.34, opacity: 0.11)
        ),
        WarmFamily(
            floatingBorder: Color(red: 0.89, green: 0.53, blue: 0.26),
            floatingFill: Color(red: 0.89, green: 0.53, blue: 0.26, opacity: 0.14),
            limitedBorder: Color(red: 0.69, green: 0.48, blue: 0.32),
            limitedFill: Color(red: 0.69, green: 0.48, blue: 0.32, opacity: 0.11)
        )
    ]

    static var warmFamilyCount: Int { warmFamilies.count }

    static func colors(
        windowID: Int,
        isFloating: Bool,
        usesLimitedVisualStyle: Bool,
        isFocused: Bool,
        isSelected: Bool = false,
        preferredWarmIndex: Int? = nil
    ) -> MapWindowPaletteColors {
        if usesLimitedVisualStyle {
            let family = warmFamilies[paletteIndex(for: windowID, preferredIndex: preferredWarmIndex)]
            return MapWindowPaletteColors(
                border: family.limitedBorder,
                fill: isSelected ? family.limitedFill.opacity(0.18) : family.limitedFill
            )
        }

        if isFloating {
            let family = warmFamilies[paletteIndex(for: windowID, preferredIndex: preferredWarmIndex)]
            return MapWindowPaletteColors(
                border: family.floatingBorder,
                fill: isSelected ? family.floatingFill.opacity(0.22) : family.floatingFill
            )
        }

        let border = isFocused ? tiledFocusedBorder : tiledBorder
        let fillOpacity: Double
        if isSelected {
            fillOpacity = 0.22
        } else if isFocused {
            fillOpacity = 0.14
        } else {
            fillOpacity = 0.09
        }
        return MapWindowPaletteColors(
            border: border,
            fill: border.opacity(fillOpacity)
        )
    }

    private static func paletteIndex(for windowID: Int, preferredIndex: Int?) -> Int {
        if let preferredIndex {
            return max(0, min(warmFamilies.count - 1, preferredIndex))
        }
        return abs(windowID) % warmFamilies.count
    }
}
