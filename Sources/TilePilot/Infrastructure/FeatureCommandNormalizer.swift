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
}
