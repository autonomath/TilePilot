import ApplicationServices
import Foundation

struct BootstrapRunResult: Sendable {
    let snapshot: SetupBootstrapSnapshot
    let managedHelperInstallState: ManagedHelperInstallState?
    let commandLogs: [CommandLogEntry]
}

final class BootstrapService: @unchecked Sendable {
    static let startAtLogonLaunchAgentLabel = "com.klode.tilepilot.launcher"
    static let startAtLogonLaunchAgentFileName = "com.klode.tilepilot.launcher.plist"
    private let runner = CommandRunner()
    private let helperService = ManagedHelperService.shared

    func runBootstrapChecks() async -> BootstrapRunResult {
        async let yabaiBinaryTask = helperService.binaryStatusItem(for: .yabai)
        async let skhdBinaryTask = helperService.binaryStatusItem(for: .skhd)
        async let yabaiServiceTask = helperService.serviceStatusItem(for: .yabai)
        async let skhdServiceTask = helperService.serviceStatusItem(for: .skhd)

        let items = [
            bundledHelpersItem(),
            await yabaiBinaryTask,
            await skhdBinaryTask,
            await yabaiServiceTask,
            await skhdServiceTask,
            startAtLogonItem(),
            accessibilityItem(),
        ]

        return BootstrapRunResult(
            snapshot: SetupBootstrapSnapshot(
                generatedAt: Date(),
                items: items,
                brewPrefix: nil
            ),
            managedHelperInstallState: helperService.loadInstallState(),
            commandLogs: []
        )
    }

    private func bundledHelpersItem() -> SetupCheckItem {
        if helperService.bundledHelpersAvailable() {
            return SetupCheckItem(
                id: "bundled-helpers",
                title: "Bundled yabai/skhd components",
                state: .installed,
                detail: "This TilePilot build includes local copies of yabai for window control and skhd for keyboard shortcuts."
            )
        }
        return SetupCheckItem(
            id: "bundled-helpers",
            title: "Bundled yabai/skhd components",
            state: .warning,
            detail: "This build does not include the local yabai/skhd components. Use the packaged app from /Applications."
        )
    }

    private func accessibilityItem() -> SetupCheckItem {
        let trusted = AXIsProcessTrusted()
        return SetupCheckItem(
            id: "accessibility-permission",
            title: "TilePilot Accessibility review",
            state: trusted ? .installed : .unknown,
            detail: trusted
                ? "Granted"
                : "Optional during setup. Review Accessibility later only if macOS prompts for TilePilot, yabai, or skhd, or if helper startup reports a permission error."
        )
    }

    private func startAtLogonItem() -> SetupCheckItem {
        let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(Self.startAtLogonLaunchAgentFileName)
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            return SetupCheckItem(
                id: "start-at-logon",
                title: "Start TilePilot at logon",
                state: .installed,
                detail: "Configured via \(launchAgentURL.path)."
            )
        }
        return SetupCheckItem(
            id: "start-at-logon",
            title: "Start TilePilot at logon",
            state: .warning,
            detail: "Not enabled. Recommended for menu bar availability after sign-in."
        )
    }
}
