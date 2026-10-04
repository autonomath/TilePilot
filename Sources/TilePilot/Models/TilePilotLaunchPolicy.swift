enum TilePilotLaunchPolicy {
    static let loginLaunchArgument = "--tilepilot-login-launch"

    static func isLoginLaunch(arguments: [String]) -> Bool {
        arguments.contains(loginLaunchArgument)
    }
}
