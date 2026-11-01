import Foundation

/// yabai and skhd check a few conditions at launch and quit at once when one fails,
/// writing a known "abort.." line to their error log. TilePilot's LaunchAgents start
/// them only once, so a helper stays stopped until the cause is fixed and the user
/// starts window control again.
enum HelperStartFailureReason: Equatable, Sendable {
    case accessibilityNotAllowed
    case separateSpacesOff
    case secureKeyboardEntry(appName: String?)
}

struct HelperStartFailure: Equatable, Sendable {
    let helper: ManagedHelperKind
    let reason: HelperStartFailureReason
}

struct HelperStartFailureAdvice: Equatable, Sendable {
    let problem: String
    let fix: String
}

enum HelperStartFailureDiagnosis {
    /// The cause named by the newest recognized abort line in `errorLog`.
    static func failure(for helper: ManagedHelperKind, errorLog: String) -> HelperStartFailure? {
        for line in errorLog.split(whereSeparator: \.isNewline).reversed() {
            if let reason = reason(for: helper, line: String(line)) {
                return HelperStartFailure(helper: helper, reason: reason)
            }
        }
        return nil
    }

    static func advice(for failures: [HelperStartFailure]) -> HelperStartFailureAdvice? {
        guard !failures.isEmpty else { return nil }
        var problems: [String] = []
        var fixes: [String] = []

        let accessibilityNames = failures
            .filter { $0.reason == .accessibilityNotAllowed }
            .map(\.helper.displayName)
        if !accessibilityNames.isEmpty {
            let names = accessibilityNames.joined(separator: " and ")
            problems.append("macOS has not allowed \(names) in Accessibility yet.")
            fixes.append("Turn on \(names) in System Settings > Privacy & Security > Accessibility.")
        }

        if failures.contains(where: { $0.reason == .separateSpacesOff }) {
            problems.append("yabai needs Displays have separate Spaces turned on.")
            fixes.append("Turn it on in System Settings > Desktop & Dock > Mission Control, then log out and back in.")
        }

        for failure in failures {
            guard case .secureKeyboardEntry(let appName) = failure.reason else { continue }
            if let appName {
                problems.append("skhd could not start because \(appName) has Secure Keyboard Entry on.")
                fixes.append("Close the password field or turn off Secure Keyboard Entry in \(appName).")
            } else {
                problems.append("skhd could not start because Secure Keyboard Entry is on.")
                fixes.append("Close any focused password field or turn off Secure Keyboard Entry.")
            }
        }

        fixes.append("Then click Start Window Control again.")
        return HelperStartFailureAdvice(
            problem: problems.joined(separator: " "),
            fix: fixes.joined(separator: " ")
        )
    }

    private static func reason(for helper: ManagedHelperKind, line: String) -> HelperStartFailureReason? {
        switch helper {
        case .yabai:
            if line.contains("could not access accessibility features") {
                return .accessibilityNotAllowed
            }
            if line.contains("'display has separate spaces' is disabled") {
                return .separateSpacesOff
            }
        case .skhd:
            if line.contains("must be run with accessibility access") {
                return .accessibilityNotAllowed
            }
            if line.contains("secure keyboard entry is enabled") {
                return .secureKeyboardEntry(appName: secureKeyboardEntryAppName(in: line))
            }
        }
        return nil
    }

    /// skhd writes `secure keyboard entry is enabled by (<pid>) '<name>'! abort..`.
    private static func secureKeyboardEntryAppName(in line: String) -> String? {
        guard let enabledBy = line.range(of: "enabled by ("),
              let nameStart = line[enabledBy.upperBound...].range(of: "'"),
              let nameEnd = line[nameStart.upperBound...].range(of: "'!") else {
            return nil
        }
        let name = line[nameStart.upperBound..<nameEnd.lowerBound].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
