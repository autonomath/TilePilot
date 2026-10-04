import AppKit
import SwiftUI

struct OverlayAccentColor: Codable, Sendable, Equatable, Hashable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    static let tiledDefault = OverlayAccentColor(red: 0.20, green: 0.50, blue: 0.95, alpha: 1.0)
    static let floatingDefault = OverlayAccentColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1.0)
    static let workSetBackdropDefault = OverlayAccentColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)

    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var nsColor: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }

    var userDefaultsArray: [Double] {
        [red, green, blue, alpha]
    }

    static func from(userDefaultsArray values: [Double]?) -> OverlayAccentColor? {
        guard let values, values.count == 4 else { return nil }
        return OverlayAccentColor(
            red: values[0],
            green: values[1],
            blue: values[2],
            alpha: values[3]
        )
    }

    static func from(swiftUIColor color: Color) -> OverlayAccentColor? {
        guard let nsColor = NSColor(color).usingColorSpace(.deviceRGB) else { return nil }
        return OverlayAccentColor(
            red: Double(nsColor.redComponent),
            green: Double(nsColor.greenComponent),
            blue: Double(nsColor.blueComponent),
            alpha: Double(nsColor.alphaComponent)
        )
    }
}
