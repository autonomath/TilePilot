import AppKit

@MainActor
enum ColorPanelPresets {
    private static let tilePilotBackdropListName = "TilePilot Backdrops"
    private static var installed = false

    private static let backdropPresets: [(name: String, color: OverlayAccentColor)] = [
        ("Charcoal", OverlayAccentColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)),
        ("Slate", OverlayAccentColor(red: 0.18, green: 0.21, blue: 0.25, alpha: 1.0)),
        ("Midnight", OverlayAccentColor(red: 0.08, green: 0.13, blue: 0.21, alpha: 1.0)),
        ("Indigo", OverlayAccentColor(red: 0.18, green: 0.15, blue: 0.30, alpha: 1.0)),
        ("Forest", OverlayAccentColor(red: 0.10, green: 0.18, blue: 0.13, alpha: 1.0)),
        ("Moss", OverlayAccentColor(red: 0.20, green: 0.22, blue: 0.12, alpha: 1.0)),
        ("Teal", OverlayAccentColor(red: 0.08, green: 0.21, blue: 0.22, alpha: 1.0)),
        ("Burgundy", OverlayAccentColor(red: 0.25, green: 0.10, blue: 0.12, alpha: 1.0)),
        ("Rust", OverlayAccentColor(red: 0.31, green: 0.16, blue: 0.10, alpha: 1.0)),
        ("Cocoa", OverlayAccentColor(red: 0.24, green: 0.17, blue: 0.13, alpha: 1.0)),
        ("Plum", OverlayAccentColor(red: 0.23, green: 0.13, blue: 0.22, alpha: 1.0)),
        ("Steel", OverlayAccentColor(red: 0.22, green: 0.24, blue: 0.28, alpha: 1.0)),
    ]

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true

        let panel = NSColorPanel.shared
        let colorList = NSColorList(name: tilePilotBackdropListName)

        for (index, preset) in backdropPresets.enumerated() {
            colorList.insertColor(preset.color.nsColor, key: preset.name, at: index)
        }

        panel.attachColorList(colorList)
        panel.showsAlpha = false
        NSColorPanel.setPickerMode(.colorList)
    }
}
