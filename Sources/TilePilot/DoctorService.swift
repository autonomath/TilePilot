import ApplicationServices
import Foundation

struct ShellCommand: Sendable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval

    init(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval = 2.0) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
    }

    var displayString: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

final class CommandRunner: @unchecked Sendable {
    func run(_ command: ShellCommand) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.runSync(command))
            }
        }
    }

    private func runSync(_ command: ShellCommand) -> CommandResult {
        let startedAt = Date()
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = mergedEnvironmentForGUIApp()

        do {
            try process.run()
        } catch {
            let endedAt = Date()
            return CommandResult(
                command: command.displayString,
                startedAt: startedAt,
                endedAt: endedAt,
                exitStatus: nil,
                stdout: "",
                stderr: error.localizedDescription,
                errorType: .launchFailure
            )
        }

        let deadline = Date().addingTimeInterval(command.timeout)
        var didTimeout = false
        while process.isRunning {
            if Date() >= deadline {
                didTimeout = true
                process.terminate()
                Thread.sleep(forTimeInterval: 0.05)
                if process.isRunning {
                    process.interrupt()
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.waitUntilExit()
        }

        let endedAt = Date()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        let errorType: CommandErrorType
        if didTimeout {
            errorType = .timeout
        } else if process.terminationStatus != 0 {
            errorType = .nonZeroExit
        } else {
            errorType = .none
        }

        return CommandResult(
            command: command.displayString,
            startedAt: startedAt,
            endedAt: endedAt,
            exitStatus: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            errorType: errorType
        )
    }

    private func mergedEnvironmentForGUIApp() -> [String: String] {
        ManagedHelperService.shared.environmentWithManagedHelpers()
    }
}

struct DoctorRunResult: Sendable {
    let snapshot: DoctorSnapshot
    let commandLogs: [CommandLogEntry]
}

final class DoctorService: @unchecked Sendable {
    private let runner = CommandRunner()

    func runDoctor() async -> DoctorRunResult {
        async let buildResultTask = runner.run(.init("/usr/bin/sw_vers", ["-buildVersion"], timeout: 1.0))
        async let yabaiVersionTask = runner.run(yabaiCommand(["--version"], timeout: 1.2))
        async let skhdVersionTask = runner.run(skhdCommand(["--version"], timeout: 1.2))
        async let yabaiDaemonTask = runner.run(.init("/usr/bin/pgrep", ["-x", "yabai"], timeout: 1.0))
        async let skhdDaemonTask = runner.run(.init("/usr/bin/pgrep", ["-x", "skhd"], timeout: 1.0))
        async let mruSpacesTask = runner.run(.init("/usr/bin/defaults", ["read", "com.apple.dock", "mru-spaces"], timeout: 1.0))
        async let spansDisplaysTask = runner.run(.init("/usr/bin/defaults", ["read", "com.apple.spaces", "spans-displays"], timeout: 1.0))
        async let yabaiQueryTask = runner.run(yabaiCommand(["-m", "query", "--displays"], timeout: 1.5))

        let buildResult = await buildResultTask
        let yabaiVersionResult = await yabaiVersionTask
        let skhdVersionResult = await skhdVersionTask
        let yabaiDaemonResult = await yabaiDaemonTask
        let skhdDaemonResult = await skhdDaemonTask
        let mruSpacesResult = await mruSpacesTask
        let spansDisplaysResult = await spansDisplaysTask
        let yabaiQueryResult = await yabaiQueryTask
        let commandResultsForLogs = [
            buildResult,
            yabaiVersionResult,
            skhdVersionResult,
            yabaiDaemonResult,
            skhdDaemonResult,
            mruSpacesResult,
            spansDisplaysResult,
            yabaiQueryResult,
        ]
        let commandLogs = makeCommandLogs(commandResultsForLogs)

        let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let macOSBuild = cleanedLine(from: buildResult.stdout)
        let systemProfile = SystemProfile(
            macOSVersion: systemVersion,
            macOSBuild: macOSBuild,
            arch: currentArchitecture(),
            yabaiVersion: cleanedLine(from: yabaiVersionResult.stdout),
            skhdVersion: cleanedLine(from: skhdVersionResult.stdout),
            detectedAt: Date()
        )

        let missionChecks = [
            missionControlCheckForMRUSpaces(mruSpacesResult),
            missionControlCheckForSpansDisplays(spansDisplaysResult),
        ]

        let accessibilityTrusted = AXIsProcessTrusted()
        let capabilities = buildCapabilities(
            accessibilityTrusted: accessibilityTrusted,
            yabaiVersionResult: yabaiVersionResult,
            skhdVersionResult: skhdVersionResult,
            yabaiDaemonResult: yabaiDaemonResult,
            skhdDaemonResult: skhdDaemonResult,
            yabaiQueryResult: yabaiQueryResult,
            missionChecks: missionChecks
        )

        let compatibilityWarnings = buildCompatibilityWarnings(
            systemProfile: systemProfile,
            missionChecks: missionChecks,
            capabilities: capabilities
        )

        let snapshot = DoctorSnapshot(
            generatedAt: Date(),
            systemProfile: systemProfile,
            capabilities: capabilities,
            missionControlChecks: missionChecks,
            compatibilityWarnings: compatibilityWarnings,
            healthBadge: deriveHealthBadge(capabilities: capabilities, missionChecks: missionChecks)
        )

        return DoctorRunResult(snapshot: snapshot, commandLogs: commandLogs)
    }

    func runSupportCommand(_ command: ShellCommand) async -> CommandResult {
        await runner.run(command)
    }

    private func buildCapabilities(
        accessibilityTrusted: Bool,
        yabaiVersionResult: CommandResult,
        skhdVersionResult: CommandResult,
        yabaiDaemonResult: CommandResult,
        skhdDaemonResult: CommandResult,
        yabaiQueryResult: CommandResult,
        missionChecks: [MissionControlCheck]
    ) -> [CapabilityState] {
        var items: [CapabilityState] = []
        let accessibilityClientName = currentAccessibilityClientName()

        items.append(
            CapabilityState(
                key: "accessibility",
                status: accessibilityTrusted ? .available : .unknown,
                reasonCode: accessibilityTrusted ? nil : "tilepilot-accessibility-optional",
                message: accessibilityTrusted ? "TilePilot Accessibility permission is granted." : "TilePilot Accessibility permission is off. This is optional unless macOS prompts for it or a focus/bring-to-front fallback fails.",
                remediationSteps: accessibilityTrusted ? [] : ["Optional: Open System Settings > Privacy & Security > Accessibility and enable \(accessibilityClientName) only if a feature you use asks for it.", "If it is already enabled there, use Recheck or relaunch TilePilot."]
            )
        )

        items.append(capabilityForToolBinary(key: "yabai-binary", title: "yabai", result: yabaiVersionResult))
        items.append(capabilityForToolBinary(key: "skhd-binary", title: "skhd", result: skhdVersionResult))
        items.append(capabilityForDaemon(key: "yabai-daemon", title: "yabai window-control service", result: yabaiDaemonResult))
        items.append(capabilityForDaemon(key: "skhd-daemon", title: "skhd shortcut service", result: skhdDaemonResult))

        items.append(
            CapabilityState(
                key: "yabai-query",
                status: statusForQuery(result: yabaiQueryResult),
                reasonCode: reasonForQuery(result: yabaiQueryResult),
                message: messageForQuery(result: yabaiQueryResult),
                remediationSteps: remediationForQuery(result: yabaiQueryResult)
            )
        )

        items.append(
            CapabilityState(
                key: "mission-control-settings",
                status: missionChecks.contains(where: { $0.status == .warning }) ? .degraded : .available,
                reasonCode: missionChecks.contains(where: { $0.status == .warning }) ? "mission-control-misconfigured" : nil,
                message: missionChecks.contains(where: { $0.status == .warning }) ? "One or more Mission Control settings may reduce yabai reliability." : "Mission Control checks look compatible (best effort).",
                remediationSteps: missionChecks.filter { $0.status == .warning }.map { $0.message }
            )
        )
        return items
    }

    private func currentAccessibilityClientName() -> String {
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return friendlyAppName(from: displayName)
        }
        if let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !bundleName.isEmpty {
            return friendlyAppName(from: bundleName)
        }
        return friendlyAppName(from: ProcessInfo.processInfo.processName)
    }

    private func friendlyAppName(from rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "TilePilot"
        }
        return trimmed
    }

    private func capabilityForToolBinary(key: String, title: String, result: CommandResult) -> CapabilityState {
        if result.errorType == .launchFailure || result.stderr.contains("No such file") {
            return CapabilityState(
                key: key,
                status: .blocked,
                reasonCode: "missing-binary",
                message: "\(title) is not installed yet.",
                remediationSteps: ["Use the packaged TilePilot app so it can install its local yabai/skhd components automatically."]
            )
        }

        if result.isSuccess, let version = cleanedLine(from: result.stdout), !version.isEmpty {
            return CapabilityState(
                key: key,
                status: .available,
                reasonCode: nil,
                message: "\(title) detected: \(version)",
                remediationSteps: []
            )
        }

        return CapabilityState(
            key: key,
            status: .unknown,
            reasonCode: "version-check-failed",
            message: "Unable to determine the \(title) version.",
            remediationSteps: ["Run System Recheck again after TilePilot finishes installing its local components."]
        )
    }

    private func capabilityForDaemon(key: String, title: String, result: CommandResult) -> CapabilityState {
        if result.exitStatus == 0 {
            return CapabilityState(
                key: key,
                status: .available,
                reasonCode: nil,
                message: "\(title) is running.",
                remediationSteps: []
            )
        }
        return CapabilityState(
            key: key,
            status: .degraded,
            reasonCode: "daemon-not-running",
            message: "\(title) is not running yet.",
            remediationSteps: ["Start window control from Guided Setup.", "If macOS prompts for Accessibility, approve the exact yabai or skhd entry named in the prompt."]
        )
    }

    private func statusForQuery(result: CommandResult) -> CapabilityStatus {
        if result.isSuccess { return .available }
        if result.stderr.localizedCaseInsensitiveContains("could not connect") { return .degraded }
        if result.errorType == .launchFailure { return .blocked }
        return .unknown
    }

    private func reasonForQuery(result: CommandResult) -> String? {
        if result.isSuccess { return nil }
        if result.stderr.localizedCaseInsensitiveContains("could not connect") { return "socket-connect-failed" }
        if result.errorType == .launchFailure { return "yabai-missing" }
        if result.errorType == .timeout { return "query-timeout" }
        return "query-failed"
    }

    private func messageForQuery(result: CommandResult) -> String {
        if result.isSuccess { return "Basic yabai query command succeeded." }
        if result.stderr.localizedCaseInsensitiveContains("could not connect") {
            return "TilePilot cannot connect to yabai yet. The window-control service may still be starting or macOS may be waiting for Accessibility approval."
        }
        return "TilePilot cannot query window state yet. Window control may still be starting or macOS may be waiting for a yabai Accessibility approval."
    }

    private func remediationForQuery(result: CommandResult) -> [String] {
        if result.isSuccess { return [] }
        if result.stderr.localizedCaseInsensitiveContains("could not connect") {
            return ["Wait a few seconds, then recheck.", "If macOS shows a yabai Accessibility prompt, approve that exact entry and recheck."]
        }
        return ["Use Guided Setup only if the services are not running.", "If macOS shows a yabai Accessibility prompt, approve that exact entry and recheck."]
    }

    private func missionControlCheckForMRUSpaces(_ result: CommandResult) -> MissionControlCheck {
        guard let actual = cleanedLine(from: result.stdout) else {
            return MissionControlCheck(
                key: "mru-spaces",
                expected: "0",
                actual: nil,
                status: .unknown,
                message: "Could not read `com.apple.dock mru-spaces` (Automatically rearrange Spaces)."
            )
        }

        if actual == "0" {
            return MissionControlCheck(
                key: "mru-spaces",
                expected: "0",
                actual: actual,
                status: .pass,
                message: "Automatically rearrange Spaces is disabled (recommended)."
            )
        }

        return MissionControlCheck(
            key: "mru-spaces",
            expected: "0",
            actual: actual,
            status: .warning,
            message: "Automatically rearrange Spaces appears enabled; yabai space indices may shift unexpectedly."
        )
    }

    private func missionControlCheckForSpansDisplays(_ result: CommandResult) -> MissionControlCheck {
        guard let actual = cleanedLine(from: result.stdout) else {
            return MissionControlCheck(
                key: "spans-displays",
                expected: "0",
                actual: nil,
                status: .unknown,
                message: "Could not read `com.apple.spaces spans-displays` (best-effort mapping for Displays have separate Spaces)."
            )
        }

        if actual == "0" {
            return MissionControlCheck(
                key: "spans-displays",
                expected: "0",
                actual: actual,
                status: .pass,
                message: "Displays have separate Spaces appears enabled (best effort)."
            )
        }

        return MissionControlCheck(
            key: "spans-displays",
            expected: "0",
            actual: actual,
            status: .warning,
            message: "Displays have separate Spaces may be disabled (best effort); multi-display behavior may be unreliable."
        )
    }

    private func buildCompatibilityWarnings(
        systemProfile: SystemProfile,
        missionChecks: [MissionControlCheck],
        capabilities: [CapabilityState]
    ) -> [String] {
        var warnings: [String] = []
        if missionChecks.contains(where: { $0.status == .warning }) {
            warnings.append("Mission Control settings may reduce predictable space behavior.")
        }
        if capabilities.contains(where: { $0.key == "yabai-query" && $0.status != .available }) {
            warnings.append("Live yabai state queries are not currently reliable.")
        }
        if systemProfile.yabaiVersion == nil {
            warnings.append("yabai version could not be detected.")
        }
        return warnings
    }

    private func deriveHealthBadge(capabilities: [CapabilityState], missionChecks: [MissionControlCheck]) -> HealthBadgeLevel {
        let badgeRelevant = capabilities.filter { $0.key != "accessibility" }

        if badgeRelevant.contains(where: { $0.status == .blocked }) {
            return .blocked
        }
        if badgeRelevant.contains(where: { $0.status == .degraded || $0.status == .unsupported }) {
            return .degraded
        }
        if badgeRelevant.contains(where: { $0.status == .unknown }) || missionChecks.contains(where: { $0.status == .warning || $0.status == .unknown }) {
            return .warning
        }
        return .healthy
    }

    private func cleanedLine(from string: String) -> String? {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func makeCommandLogs(_ results: [CommandResult]) -> [CommandLogEntry] {
        results
            .map { result in
                CommandLogEntry(
                    id: UUID(),
                    command: result.command,
                    startedAt: result.startedAt,
                    endedAt: result.endedAt,
                    durationMs: result.durationMs,
                    exitStatus: result.exitStatus,
                    stdoutSnippet: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160).description,
                    stderrSnippet: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160).description,
                    errorType: result.errorType
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
    }
}
