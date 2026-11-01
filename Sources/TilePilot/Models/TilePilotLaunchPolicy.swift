enum TilePilotLaunchPolicy {
    static let loginLaunchArgument = "--tilepilot-login-launch"

    static func isLoginLaunch(arguments: [String]) -> Bool {
        arguments.contains(loginLaunchArgument)
    }

    /// A mounted disk image is read-only, and App Translocation runs a quarantined app from a
    /// read-only random path. Neither location survives, so login items must not point there.
    static func isTemporaryAppLocation(bundlePath: String, volumeIsReadOnly: Bool) -> Bool {
        volumeIsReadOnly || bundlePath.contains("/AppTranslocation/")
    }
}
