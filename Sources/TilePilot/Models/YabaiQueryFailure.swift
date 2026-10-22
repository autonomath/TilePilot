import Foundation

enum YabaiQueryFailure {
    static func summary(
        windows: CommandResult,
        spaces: CommandResult,
        displays: CommandResult,
        timeout: TimeInterval
    ) -> String? {
        let failures = [("--windows", windows), ("--spaces", spaces), ("--displays", displays)]
            .filter { !$0.1.isSuccess }
        guard !failures.isEmpty else { return nil }

        let details = failures.map { query, result in
            let command = "yabai \(query) query"
            if result.errorType == .timeout {
                let seconds = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), timeout)
                return "\(command) timed out after \(seconds) seconds."
            }

            // stdout is window/desktop data, never a diagnostic. Only known
            // stderr failures become user-facing guidance; keep unknown payloads out.
            let stderr = result.stderr.lowercased()
            if stderr.contains("permission") && stderr.contains("denied") {
                return "\(command): permission denied. Review Accessibility access in Guided Setup."
            }
            if stderr.contains("could not connect") || stderr.contains("message socket")
                || stderr.contains("failed to connect to socket") || stderr.contains("socket unavailable") {
                return "\(command): socket unavailable. Start window control from Guided Setup."
            }
            if result.errorType == .launchFailure || stderr.contains("no such file or directory")
                || stderr.contains("not found") {
                return "\(command) could not start. Run Guided Setup to check the helper installation."
            }
            let status = result.exitStatus.map { " (exit \($0))" } ?? ""
            return "\(command) failed\(status)."
        }
        return details.joined(separator: " ") + " TilePilot will retry automatically."
    }
}
