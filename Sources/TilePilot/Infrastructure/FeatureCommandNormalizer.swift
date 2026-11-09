import Foundation

enum FeatureCommandNormalizer {
    static func normalize(_ raw: String) -> String {
        var command = raw
            .replacingOccurrences(of: #"^\s*/usr/bin/env\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*env\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        command = command.replacingOccurrences(of: #"/usr/bin/open"#, with: "open", options: .regularExpression)
        command = command.replacingOccurrences(of: "tilepilot:/feature/", with: "tilepilot://feature/")
        command = command.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return command
    }

    /// Reads the default desktop lines as the yabai commands they stand for, so the Shortcuts list
    /// groups and names them like hand-written ones: a TilePilot desktop link is "go to desktop N",
    /// and `window --space N --focus` moves the window and follows it there.
    static func desktopEquivalent(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"(?:/usr/bin/)?open -g "?tilepilot://desktop/(\d+)"?"#,
            with: "yabai -m space --focus $1",
            options: [.regularExpression, .caseInsensitive]
        )
        .replacingOccurrences(
            of: #"yabai -m window --space (\d+) --focus(?=\s*(?:$|[;&|]))"#,
            with: "yabai -m window --space $1; yabai -m space --focus $1",
            options: .regularExpression
        )
    }
}
