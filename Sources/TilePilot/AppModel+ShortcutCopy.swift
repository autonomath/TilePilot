import Foundation

@MainActor
extension AppModel {
    func shortcutExplanation(combo: String, command: String, category: String) -> String {
        let c = command.lowercased()
        let normalized = normalizedFeatureMatchCommand(c)

        if normalized.contains("tilepilot://feature/screen.bring-floating-front") {
            return "Raises floating windows above the other windows on the current desktop."
        }
        if normalized.contains("tilepilot://feature/screen.set-floating-all-visible") {
            return "Stops tiling the windows on this desktop so you can move and overlap them freely."
        }
        if normalized.contains("tilepilot://feature/screen.set-tiled-all-visible") {
            return "Puts eligible windows on this desktop back into tiles and leaves Never Auto-Tile apps floating."
        }
        if normalized.contains("tilepilot://feature/screen.grid-floating") {
            return "Places the windows on this desktop into a simple grid and leaves them floating."
        }
        if normalized.contains("tilepilot://feature/screen.grid-auto-tiled") {
            return "Retiles eligible windows on this desktop into a balanced layout and leaves Never Auto-Tile apps floating."
        }
        if normalized.contains("tilepilot://feature/app.keep-on-top-when-floating") {
            return "Toggles keep-on-top for the focused app when floating."
        }
        if normalized.contains("tilepilot://feature/app.never-auto-tile") {
            return "Keeps the focused app out of tiled layouts."
        }
        if normalized.contains("tilepilot://feature/app.open-megamap") {
            return "Opens the large screenshot-based view of all desktops."
        }
        if normalized.contains("tilepilot://feature/app.run-guided-setup") {
            return "Opens the step-by-step setup assistant."
        }
        if normalized.contains("tilepilot://feature/app.refresh-megamap") {
            return "Visibly sweeps desktops and captures fresh MegaMap screenshots."
        }
        if normalized.contains("open -a \"tilepilot\"") || normalized.contains("open -a tilepilot") {
            return "Brings TilePilot to the front."
        }

        if c.contains("grid-tiling-floating.sh") {
            return "Places the windows on this desktop into a simple grid and leaves them floating."
        }
        if c.contains("rebuild-balanced-tile-layout.sh") {
            return "Retiles eligible windows on this desktop into a balanced layout and leaves Never Auto-Tile apps floating."
        }
        if c.contains("grid-tiling-auto-tiled.sh") {
            return "Retiles eligible windows on this desktop into a balanced layout and leaves Never Auto-Tile apps floating."
        }
        if c.contains("grid-pack-toggle.sh") {
            return "Legacy helper for arranging the windows on this desktop into a floating grid."
        }

        if c.contains("yabai -m window --space"), c.contains("yabai -m space --focus") {
            if let target = firstInteger(after: "--space", in: c) ?? firstInteger(after: "--focus", in: c) {
                return "Moves the focused window to Desktop \(target), then switches to Desktop \(target)."
            }
            return "Moves the focused window to another desktop, then switches there."
        }
        if c.contains("yabai -m window --space") {
            if let target = firstInteger(after: "--space", in: c) {
                return "Moves the focused window to Desktop \(target)."
            }
            return "Moves the focused window to another desktop."
        }
        if c.contains("yabai -m space --focus"), let target = firstInteger(after: "--focus", in: c) {
            return "Switches to Desktop \(target)."
        }

        if c.contains("yabai -m window --toggle float") {
            return "Switches the focused window between tiled and floating."
        }
        if c.contains("yabai -m window --focus west") { return "Moves focus to the window on the left." }
        if c.contains("yabai -m window --focus east") { return "Moves focus to the window on the right." }
        if c.contains("yabai -m window --focus north") { return "Moves focus to the window above." }
        if c.contains("yabai -m window --focus south") { return "Moves focus to the window below." }
        if c.contains("yabai -m window --swap west") { return "Swaps the focused window with the window on the left." }
        if c.contains("yabai -m window --swap east") { return "Swaps the focused window with the window on the right." }
        if c.contains("yabai -m window --swap north") { return "Swaps the focused window with the window above." }
        if c.contains("yabai -m window --swap south") { return "Swaps the focused window with the window below." }
        if c.contains("yabai -m window --warp west") { return "Moves the focused window into the left tile position." }
        if c.contains("yabai -m window --warp east") { return "Moves the focused window into the right tile position." }
        if c.contains("yabai -m window --warp north") { return "Moves the focused window into the upper tile position." }
        if c.contains("yabai -m window --warp south") { return "Moves the focused window into the lower tile position." }
        if c.contains("yabai -m window --resize left:") { return "Resizes the focused window from the left edge (left)." }
        if c.contains("yabai -m window --resize right:") { return "Resizes the focused window from the right edge (right)." }
        if c.contains("yabai -m window --resize top:") { return "Resizes the focused window from the top edge (up)." }
        if c.contains("yabai -m window --resize bottom:") { return "Resizes the focused window from the bottom edge (down)." }
        if c.contains("yabai -m window --resize") { return "Resizes the focused window." }
        if c.contains("yabai -m space --balance") { return "Redistributes space so tiled windows on this desktop are closer in size." }
        if c.contains("yabai -m space --rotate") {
            if let degrees = firstInteger(after: "--rotate", in: c) {
                return "Rotates the current desktop layout by \(degrees) degrees."
            }
            return "Rotates the current desktop layout."
        }
        if c.contains("yabai -m space --layout bsp") { return "Turns on tiled layout for this desktop." }
        if c.contains("yabai -m space --layout stack") { return "Sets the current desktop layout to a stack." }
        if c.contains("yabai -m space --focus prev") { return "Jumps to the previous desktop." }
        if c.contains("yabai -m space --focus next") { return "Jumps to the next desktop." }
        if c.contains("yabai -m space --focus") { return "Jumps to a specific desktop." }
        if c.contains("yabai -m display --focus") { return "Moves focus to another display." }
        if c.contains("yabai -m window --display") { return "Sends the focused window to another display." }
        if c.contains("open -a ") || c.hasPrefix("open ") {
            return "Opens an app or file."
        }
        if c.contains("osascript") {
            return "Runs an AppleScript automation."
        }
        if c.contains("skhd -k") {
            return "Triggers another keyboard sequence."
        }
        if let scriptDescription = scriptShortcutDescription(command: command) {
            return scriptDescription
        }

        switch category {
        case "Windows":
            return "Runs a window shortcut from your skhd config."
        case "Spaces":
            return "Runs a desktop shortcut from your skhd config."
        case "Displays":
            return "Runs a display shortcut from your skhd config."
        case "Apps":
            return "Opens an app or file."
        case "Macros":
            return "Runs a helper macro from your skhd config."
        default:
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "No command is configured on this line." }
            let snippet = trimmed.count > 72 ? String(trimmed.prefix(69)) + "..." : trimmed
            return "Runs: \(snippet)"
        }
    }

    func firstInteger(after flag: String, in text: String) -> Int? {
        guard let range = text.range(of: flag) else { return nil }
        let suffix = text[range.upperBound...]
        let digits = suffix.firstMatch(of: /[^\d]*(\d+)/)?.1
        if let digits {
            return Int(String(digits))
        }
        return nil
    }

    func shortcutTitle(for entry: ShortcutEntry) -> String {
        if let feature = featureDefinition(for: entry) {
            return feature.title
        }
        let c = entry.command.lowercased()
        let normalized = normalizedFeatureMatchCommand(c)

        if normalized.contains("tilepilot://feature/screen.bring-floating-front") {
            return "Bring Floating Windows to Front"
        }
        if normalized.contains("tilepilot://feature/screen.set-floating-all-visible") {
            return "Float All Windows on This Desktop"
        }
        if normalized.contains("tilepilot://feature/screen.set-tiled-all-visible") {
            return "Tile All Windows on This Desktop"
        }
        if normalized.contains("tilepilot://feature/screen.grid-floating") {
            return "Arrange Windows into a Floating Grid"
        }
        if normalized.contains("tilepilot://feature/screen.grid-auto-tiled") {
            return "Retile Windows into a Balanced Tiled Layout"
        }
        if normalized.contains("tilepilot://feature/app.keep-on-top-when-floating") {
            return "Keep App on Top"
        }
        if normalized.contains("tilepilot://feature/app.never-auto-tile") {
            return "Never Auto-Tile App"
        }
        if normalized.contains("tilepilot://feature/app.open-megamap") {
            return "Open MegaMap"
        }
        if normalized.contains("tilepilot://feature/app.run-guided-setup") {
            return "Run Guided Setup"
        }
        if normalized.contains("tilepilot://feature/app.refresh-megamap") {
            return "Refresh MegaMap"
        }
        if normalized.contains("open -a \"tilepilot\"") || normalized.contains("open -a tilepilot") {
            return "Open TilePilot"
        }

        if c.contains("grid-tiling-floating.sh") {
            return "Arrange Windows into a Floating Grid"
        }
        if c.contains("rebuild-balanced-tile-layout.sh") {
            return "Retile Windows into a Balanced Tiled Layout"
        }
        if c.contains("grid-tiling-auto-tiled.sh") {
            return "Retile Windows into a Balanced Tiled Layout"
        }
        if c.contains("grid-pack-toggle.sh") {
            return "Arrange Windows into a Floating Grid (Legacy)"
        }
        if c.contains("auto-layout-current-desktop.sh") || c.contains("readable-current-space.sh") {
            return "Arrange Windows into a Floating Grid"
        }

        if c.contains("yabai -m window --space"), c.contains("yabai -m space --focus"),
           let target = firstInteger(after: "--space", in: c) ?? firstInteger(after: "--focus", in: c) {
            return "Move Window to Desktop \(target)"
        }
        if c.contains("yabai -m space --focus"),
           let target = firstInteger(after: "--focus", in: c) {
            return "Jump to Desktop \(target)"
        }
        if c.contains("yabai -m window --focus west") { return "Focus Left" }
        if c.contains("yabai -m window --focus east") { return "Focus Right" }
        if c.contains("yabai -m window --focus north") { return "Focus Up" }
        if c.contains("yabai -m window --focus south") { return "Focus Down" }
        if c.contains("yabai -m window --warp west") { return "Move Window Left" }
        if c.contains("yabai -m window --warp east") { return "Move Window Right" }
        if c.contains("yabai -m window --warp north") { return "Move Window Up" }
        if c.contains("yabai -m window --warp south") { return "Move Window Down" }
        if c.contains("yabai -m window --resize left:") { return "Resize Left" }
        if c.contains("yabai -m window --resize right:") { return "Resize Right" }
        if c.contains("yabai -m window --resize top:") { return "Resize Up" }
        if c.contains("yabai -m window --resize bottom:") { return "Resize Down" }
        if c.contains("yabai -m window --toggle float") { return "Toggle Float/Tile" }
        if c.contains("yabai -m space --layout bsp"), c.contains("yabai -m space --balance") { return "Set This Desktop to Tiled Layout and Rebalance" }
        if c.contains("yabai -m space --layout stack") { return "Stack Layout" }
        if c.contains("yabai -m space --balance") { return "Rebalance Tiled Window Sizes" }
        if c.contains("yabai -m space --rotate") { return "Rotate Layout" }

        if let scriptPath = scriptPath(from: entry.command) {
            return scriptDisplayTitle(from: scriptPath)
        }

        return shortcutExplanation(entry)
    }

    func normalizedShortcutCopy(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func scriptPath(from command: String) -> String? {
        guard let firstTokenRaw = command.split(whereSeparator: \.isWhitespace).first else { return nil }
        let firstToken = String(firstTokenRaw).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let loweredToken = firstToken.lowercased()
        if loweredToken == "env" || loweredToken.hasSuffix("/env") || loweredToken == "open" || loweredToken.hasSuffix("/open") {
            return nil
        }
        guard firstToken.hasPrefix("/") || firstToken.hasPrefix("~/") || firstToken.hasPrefix("./") else { return nil }

        if firstToken.hasPrefix("./") {
            let baseURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config")
                .appendingPathComponent("skhd", isDirectory: true)
            return URL(fileURLWithPath: firstToken, relativeTo: baseURL)
                .standardizedFileURL
                .path
        }

        return NSString(string: firstToken).expandingTildeInPath
    }

    func scriptDisplayTitle(from path: String) -> String {
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        switch base.lowercased() {
        case "bootstrap":
            return "Legacy: Reset Desktop and Display Setup"
        case "auto-layout-current-desktop", "readable-current-space":
            return "Arrange Windows into a Floating Grid"
        default:
            break
        }
        let cleaned = base.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
        let tokens = cleaned
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return "Script Action" }
        return tokens
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    func scriptDescriptionFromHeader(path: String) -> String? {
        if let cached = scriptHeaderDescriptionCache[path] {
            return cached
        }

        let description: String?
        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
            description = content
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .prefix(20)
                .compactMap { rawLine -> String? in
                    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.isEmpty || line.hasPrefix("#!") || !line.hasPrefix("#") { return nil }
                    let comment = String(line.dropFirst())
                        .trimmingCharacters(in: CharacterSet(charactersIn: " .:-\t"))
                    guard !comment.isEmpty else { return nil }
                    if comment.hasSuffix(".") || comment.hasSuffix("!") || comment.hasSuffix("?") {
                        return comment
                    }
                    return comment + "."
                }
                .first
        } else {
            description = nil
        }

        scriptHeaderDescriptionCache[path] = description
        return description
    }

    func scriptFallbackDescription(from path: String) -> String {
        let title = scriptDisplayTitle(from: path)
        return "Uses the \(title.lowercased()) helper."
    }

    private func scriptShortcutDescription(command: String) -> String? {
        guard let path = scriptPath(from: command) else { return nil }
        if let header = scriptDescriptionFromHeader(path: path) {
            return header
        }
        return scriptFallbackDescription(from: path)
    }
}
