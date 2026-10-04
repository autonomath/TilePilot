import Foundation

/// Starting yabai/skhd triggers a macOS Accessibility permission prompt.
/// TilePilot must never trigger that prompt before the user explicitly
/// starts window control once, with an explanation of what the prompt is for.
enum HelperStartConsentPolicy {
    static let consentDefaultsKey = "TilePilot.windowControlStartConsented"

    /// Automatic (non-user-initiated) service starts are allowed only after
    /// a prior explicit user-initiated start on this machine.
    static func allowsAutomaticStart(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: consentDefaultsKey)
    }

    static func recordUserInitiatedStart(userDefaults: UserDefaults = .standard) {
        userDefaults.set(true, forKey: consentDefaultsKey)
    }
}
