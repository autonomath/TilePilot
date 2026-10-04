import AppKit
import ApplicationServices
import Foundation

@MainActor
extension AppModel {
    private var helperService: ManagedHelperService {
        ManagedHelperService.shared
    }

    func exportDiagnostics() {
        guard let snapshot = doctorSnapshot else {
            lastErrorMessage = "Run System Recheck before exporting diagnostics."
            return
        }

        let report = DiagnosticsReport(
            generatedAt: Date(),
            systemProfile: snapshot.systemProfile,
            health: snapshot,
            capabilities: snapshot.capabilities,
            recentCommands: Array(commandLogs.prefix(50))
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(report)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop")
                .appendingPathComponent("tilepilot-diagnostics-\(stamp).json")
            try data.write(to: url, options: .atomic)
            lastExportURL = url
            lastErrorMessage = nil
            lastActionMessage = "Diagnostics exported to \(url.lastPathComponent)"
        } catch {
            lastErrorMessage = "Diagnostics export failed: \(error.localizedDescription)"
        }
    }

    func copyIssueReadySummary() {
        guard let snapshot = doctorSnapshot else {
            lastErrorMessage = "Run System Recheck before copying a status summary."
            return
        }

        let failing = snapshot.capabilities
            .filter { $0.status != .available }
            .sorted { $0.status.severityRank > $1.status.severityRank }

        var lines: [String] = []
        lines.append("TilePilot Status Summary")
        lines.append("Generated: \(snapshot.generatedAt.formatted(date: .abbreviated, time: .standard))")
        lines.append("macOS: \(snapshot.systemProfile.macOSVersion)")
        lines.append("Build: \(snapshot.systemProfile.macOSBuild ?? "unknown")")
        lines.append("Arch: \(snapshot.systemProfile.arch)")
        lines.append("yabai: \(snapshot.systemProfile.yabaiVersion ?? "not detected")")
        lines.append("skhd: \(snapshot.systemProfile.skhdVersion ?? "not detected")")
        lines.append("Health: \(snapshot.healthBadge.title)")
        lines.append("")
        lines.append("Capabilities:")
        for item in failing.prefix(8) {
            lines.append("- \(item.key): \(item.status.rawValue) (\(item.reasonCode ?? "no-reason"))")
            lines.append("  \(item.message)")
        }
        if !snapshot.compatibilityWarnings.isEmpty {
            lines.append("")
            lines.append("Warnings:")
            snapshot.compatibilityWarnings.forEach { lines.append("- \($0)") }
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        lastErrorMessage = nil
        lastActionMessage = "Issue-ready summary copied to clipboard."
    }

    func installManagedHelpers() {
        Task { [weak self] in
            guard let self else { return }
            let existingInstalls = await self.helperService.detectExistingExternalHelpers()

            if !existingInstalls.isEmpty {
                await MainActor.run {
                    self.helperMigrationPrompt = HelperMigrationPromptState(installs: existingInstalls)
                    self.lastErrorMessage = nil
                    self.lastActionMessage = "TilePilot found an existing yabai/skhd install. Choose whether to keep it or replace it."
                }
                return
            }

            await self.performManagedHelperInstall(replacingExternalInstall: false)
        }
    }

    func bootstrapResultAfterAutomaticManagedHelperInstallIfNeeded(_ result: BootstrapRunResult) async -> BootstrapRunResult {
        guard shouldAutomaticallyInstallManagedHelpers(from: result) else {
            return result
        }

        hasAttemptedAutomaticManagedHelperInstall = true
        isLaunchingSetupInstaller = true
        lastActionMessage = "Installing TilePilot window-control components..."
        lastErrorMessage = nil

        // Never auto-start services on a fresh install: starting yabai/skhd fires the
        // macOS Accessibility prompt, which must wait for an explicit user start.
        let allowAutomaticStart = HelperStartConsentPolicy.allowsAutomaticStart()
        let installResult = await helperService.installBundledHelpers(startServicesAfterInstall: allowAutomaticStart)

        isLaunchingSetupInstaller = false
        applyManagedHelperOperationResult(installResult)

        guard installResult.errorMessage == nil else {
            return result
        }

        guard allowAutomaticStart else {
            return await bootstrapService.runBootstrapChecks()
        }
        return await waitForBootstrapWindowControlServicesToSettle()
    }

    func bootstrapResultAfterAutomaticManagedHelperStartIfNeeded(_ result: BootstrapRunResult) async -> BootstrapRunResult {
        guard shouldAutomaticallyStartManagedHelperServices(from: result) else {
            return result
        }

        hasAttemptedAutomaticManagedHelperServiceStart = true
        isLaunchingSetupInstaller = true
        lastActionMessage = "Starting TilePilot window-control services..."
        lastErrorMessage = nil

        let startResult = await helperService.startManagedServices()

        isLaunchingSetupInstaller = false
        applyManagedHelperOperationResult(startResult)

        guard startResult.errorMessage == nil else {
            return await bootstrapService.runBootstrapChecks()
        }

        return await waitForBootstrapWindowControlServicesToSettle()
    }

    func keepExistingHelperInstall() {
        helperMigrationPrompt = nil
        lastErrorMessage = nil
        lastActionMessage = "Keeping the existing yabai/skhd install. TilePilot will use the external binaries."
        Task { [weak self] in
            await self?.refreshBootstrapSetup()
            await self?.refreshDoctor()
        }
    }

    func replaceWithManagedHelpers() {
        guard !isLaunchingSetupInstaller else { return }
        helperMigrationPrompt = nil
        // The user is migrating an already-running external install; starting the
        // managed services is the explicit point of this action.
        HelperStartConsentPolicy.recordUserInitiatedStart()
        Task { [weak self] in
            guard let self else { return }
            await self.performManagedHelperInstall(replacingExternalInstall: true)
        }
    }

    func dismissHelperMigrationPrompt() {
        helperMigrationPrompt = nil
    }

    private func performManagedHelperInstall(replacingExternalInstall: Bool) async {
        await MainActor.run {
            self.isLaunchingSetupInstaller = true
        }

        let result = replacingExternalInstall
            ? await self.helperService.installBundledHelpersReplacingExternalServices()
            : await self.helperService.installBundledHelpers(
                startServicesAfterInstall: HelperStartConsentPolicy.allowsAutomaticStart()
            )

        await MainActor.run {
            self.isLaunchingSetupInstaller = false
            self.applyManagedHelperOperationResult(result)
        }

        await self.refreshBootstrapSetup()
        await self.refreshDoctor()
    }

    private func shouldAutomaticallyInstallManagedHelpers(from result: BootstrapRunResult) -> Bool {
        guard !hasAttemptedAutomaticManagedHelperInstall else { return false }
        guard !isLaunchingSetupInstaller else { return false }
        guard helperService.bundledHelpersAvailable() else { return false }

        let itemsByID = Dictionary(uniqueKeysWithValues: result.snapshot.items.map { ($0.id, $0) })
        guard itemsByID["bundled-helpers"]?.state == .installed else { return false }

        let missingRequiredBinary = ["yabai-binary", "skhd-binary"].contains { id in
            itemsByID[id]?.state != .installed
        }
        guard missingRequiredBinary else { return false }

        // Do not replace external setups here. The bootstrap check already treats a usable
        // external yabai/skhd binary as installed, so this only covers true first-run absence.
        return !helperService.hasManagedHelperInstall()
    }

    private func shouldAutomaticallyStartManagedHelperServices(from result: BootstrapRunResult) -> Bool {
        guard !hasAttemptedAutomaticManagedHelperServiceStart else { return false }
        guard !isLaunchingSetupInstaller else { return false }
        // Automatic starts are only allowed after the user has explicitly started
        // window control once; otherwise macOS permission prompts appear unprompted.
        guard HelperStartConsentPolicy.allowsAutomaticStart() else { return false }
        guard helperService.hasManagedHelperInstall() else { return false }
        guard bootstrapManagedHelperBinariesInstalled(in: result.snapshot) else { return false }
        return !bootstrapWindowControlServicesRunning(in: result.snapshot)
    }

    func runSetupInstallerInTerminal() {
        installManagedHelpers()
    }

    func runScriptingAdditionRepairInTerminal() {
        acknowledgeInitialStatusIfNeeded()
        lastErrorMessage = "This desktop-control repair flow is not supported by TilePilot."
        lastActionMessage = nil
    }

    func openSystemSettings() {
        openURLCandidates([
            "x-apple.systempreferences:",
        ])
    }

    func openAccessibilitySettings() {
        openURLCandidates([
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:",
        ])
    }

    func requestAccessibilityAccessPrompt() {
        acknowledgeInitialStatusIfNeeded()
        let alreadyTrusted = AXIsProcessTrusted()
        if alreadyTrusted {
            lastActionMessage = "Accessibility access is already granted."
            lastErrorMessage = nil
            return
        }

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        lastActionMessage = "Requested Accessibility access prompt. If no prompt appears, open Accessibility Settings manually."
        lastErrorMessage = nil
        scheduleSetupRefreshAfterExternalHandoff(delaySeconds: 1.0)
    }

    func requestScreenRecordingAccessPrompt() {
        acknowledgeInitialStatusIfNeeded()
        let alreadyAuthorized = megamapCaptureService.screenRecordingAuthorized()
        if alreadyAuthorized {
            megamapScreenRecordingAuthorized = true
            lastActionMessage = "Screen Recording access is already granted."
            lastErrorMessage = nil
            return
        }

        _ = megamapCaptureService.requestScreenRecordingAccess()
        megamapScreenRecordingAuthorized = megamapCaptureService.screenRecordingAuthorized()
        megamapCaptureService.openScreenRecordingSettings()
        if megamapScreenRecordingAuthorized {
            lastActionMessage = "Screen Recording access confirmed."
            lastErrorMessage = nil
        } else {
            lastActionMessage = "Opened Screen Recording settings."
            lastErrorMessage = "If TilePilot is not listed yet, macOS has not registered the capture request. Reopen TilePilot and try Enable Screen Recording again."
        }
        scheduleSetupRefreshAfterExternalHandoff(delaySeconds: 1.0)
    }

    func openScreenRecordingSettings() {
        acknowledgeInitialStatusIfNeeded()
        _ = megamapCaptureService.requestScreenRecordingAccess()
        megamapCaptureService.openScreenRecordingSettings()
        lastActionMessage = "Opened Screen Recording settings."
        lastErrorMessage = "If TilePilot is not listed yet, macOS has not registered the capture request. Reopen TilePilot and try Enable Screen Recording again."
        scheduleSetupRefreshAfterExternalHandoff(delaySeconds: 1.0)
    }

    func openMissionControlSettings() {
        openURLCandidates([
            "x-apple.systempreferences:com.apple.preference.expose",
            "x-apple.systempreferences:",
        ])
    }

    func openMissionControlKeyboardShortcuts() {
        openURLCandidates([
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?KeyboardShortcuts=MissionControl",
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?KeyboardShortcuts/MissionControl",
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?KeyboardShortcuts",
            "x-apple.systempreferences:com.apple.preference.keyboard?KeyboardShortcutsTab",
            "x-apple.systempreferences:com.apple.preference.keyboard",
            "x-apple.systempreferences:",
        ])
    }

    func openLoginItemsSettings() {
        openURLCandidates([
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.systempreferences.GeneralSettings",
            "x-apple.systempreferences:",
        ])
    }

    func enableStartAtLogon() {
        acknowledgeInitialStatusIfNeeded()

        do {
            try writeStartAtLogonLaunchAgent()
            lastActionMessage = "Enabled start at logon."
            lastErrorMessage = nil
            Task { [weak self] in
                await self?.refreshBootstrapSetup()
            }
        } catch {
            lastErrorMessage = "Failed to enable start at logon: \(error.localizedDescription)"
            lastActionMessage = nil
        }
    }

    func updateStartAtLogonLaunchAgentIfNeeded() {
        let plistURL = startAtLogonLaunchAgentURL()
        guard FileManager.default.fileExists(atPath: plistURL.path),
              let currentPlist = try? String(contentsOf: plistURL, encoding: .utf8),
              currentPlist != startAtLogonLaunchAgentPlist() else {
            return
        }

        try? writeStartAtLogonLaunchAgent()
    }

    func restartYabaiBestEffort() {
        HelperStartConsentPolicy.recordUserInitiatedStart()
        if helperService.hasManagedHelperInstall() {
            if managedHelperInstallState?.launchAgentsInstalled != true {
                startHelperServicesBestEffort()
                return
            }
            runSupportCommand(
                yabaiCommand(["--restart-service"], timeout: 2.0),
                successMessage: "Requested yabai service restart."
            )
        } else {
            runSupportCommand(
                yabaiCommand(["--start-service"], timeout: 2.0),
                successMessage: "Requested yabai service start."
            )
        }
    }

    func restartSkhdBestEffort() {
        HelperStartConsentPolicy.recordUserInitiatedStart()
        Task { [weak self] in
            guard let self else { return }
            let reloadResult = await self.doctorService.runSupportCommand(
                skhdCommand(["--reload"], timeout: 2.0)
            )
            var fallbackResult: CommandResult?
            var managedStartResult: ManagedHelperOperationResult?

            if !reloadResult.isSuccess {
                if helperService.hasManagedHelperInstall(), self.managedHelperInstallState?.launchAgentsInstalled != true {
                    managedStartResult = await self.helperService.startManagedServices()
                } else {
                    let fallbackCommand = helperService.hasManagedHelperInstall()
                        ? skhdCommand(["--restart-service"], timeout: 2.0)
                        : skhdCommand(["--start-service"], timeout: 2.0)
                    fallbackResult = await self.doctorService.runSupportCommand(fallbackCommand)
                }
            }

            await MainActor.run {
                self.appendCommandLog(from: reloadResult)
                if let fallbackResult {
                    self.appendCommandLog(from: fallbackResult)
                }
                if let managedStartResult {
                    self.applyManagedHelperOperationResult(managedStartResult)
                }

                if reloadResult.isSuccess {
                    self.lastActionMessage = "Requested skhd config reload."
                    self.lastErrorMessage = nil
                } else if fallbackResult?.isSuccess == true {
                    self.lastActionMessage = helperService.hasManagedHelperInstall()
                        ? "Requested skhd service restart."
                        : "Requested skhd service start."
                    self.lastErrorMessage = nil
                } else if let managedStartResult, managedStartResult.errorMessage == nil {
                    self.lastActionMessage = managedStartResult.successMessage ?? "Started TilePilot window-control services."
                    self.lastErrorMessage = nil
                } else {
                    let stderrReload = reloadResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    let stderrFallback = fallbackResult?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let stderrManaged = managedStartResult?.errorMessage ?? ""
                    let stderr = [stderrReload, stderrFallback, stderrManaged].filter { !$0.isEmpty }.joined(separator: " | ")
                    self.lastErrorMessage = stderr.isEmpty
                        ? "Could not restart skhd."
                        : "skhd reload/start failed: \(trimForUI(stderr))"
                    self.lastActionMessage = nil
                }
            }

            await self.refreshBootstrapSetup()
            await self.refreshDoctor()
        }
    }

    func startBrewServiceYabai() {
        startYabaiBestEffort()
    }

    func startBrewServiceSkhd() {
        startSkhdBestEffort()
    }

    func startWindowControlBestEffort() {
        HelperStartConsentPolicy.recordUserInitiatedStart()
        if helperService.hasManagedHelperInstall() {
            startHelperServicesBestEffort()
            return
        }

        startYabaiBestEffort()
        startSkhdBestEffort()
    }

    func startYabaiBestEffort() {
        HelperStartConsentPolicy.recordUserInitiatedStart()
        if helperService.hasManagedHelperInstall() {
            startHelperServicesBestEffort()
            return
        }

        runSupportCommand(
            yabaiCommand(["--start-service"], timeout: 2.0),
            successMessage: "Requested yabai service start."
        )
    }

    func startSkhdBestEffort() {
        HelperStartConsentPolicy.recordUserInitiatedStart()
        if helperService.hasManagedHelperInstall() {
            startHelperServicesBestEffort()
            return
        }

        runSupportCommand(
            skhdCommand(["--start-service"], timeout: 2.0),
            successMessage: "Requested skhd service start."
        )
    }

    func startHelperServicesBestEffort() {
        // Every caller of this function is a direct user action.
        HelperStartConsentPolicy.recordUserInitiatedStart()
        Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.isLaunchingSetupInstaller = true
                self.hasAttemptedAutomaticManagedHelperServiceStart = true
            }
            let result = await self.helperService.startManagedServices()

            await MainActor.run {
                self.isLaunchingSetupInstaller = false
                self.applyManagedHelperOperationResult(result)
            }

            await self.refreshSetupAfterWindowControlStart()
        }
    }

    private func refreshSetupAfterWindowControlStart(maxAttempts: Int = 6, delaySeconds: Double = 0.7) async {
        for attempt in 0..<maxAttempts {
            await refreshBootstrapSetup()
            await refreshDoctor()
            if windowControlReadyForSetup {
                return
            }
            if attempt < maxAttempts - 1 {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }
        }
    }

    private func waitForBootstrapWindowControlServicesToSettle(maxAttempts: Int = 6, delaySeconds: Double = 0.5) async -> BootstrapRunResult {
        var latest = await bootstrapService.runBootstrapChecks()
        if bootstrapWindowControlServicesRunning(in: latest.snapshot) {
            return latest
        }

        for attempt in 1..<maxAttempts {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }
            latest = await bootstrapService.runBootstrapChecks()
            if bootstrapWindowControlServicesRunning(in: latest.snapshot) {
                return latest
            }
        }

        return latest
    }

    private func bootstrapManagedHelperBinariesInstalled(in snapshot: SetupBootstrapSnapshot) -> Bool {
        let itemsByID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        return itemsByID["yabai-binary"]?.state == .installed &&
            itemsByID["skhd-binary"]?.state == .installed
    }

    private func bootstrapWindowControlServicesRunning(in snapshot: SetupBootstrapSnapshot) -> Bool {
        let itemsByID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        return itemsByID["helper-service-yabai"]?.state == .installed &&
            itemsByID["helper-service-skhd"]?.state == .installed
    }

    private func openURLCandidates(_ candidates: [String], updateMessaging: Bool = true) {
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                if updateMessaging {
                    lastActionMessage = "Opened System Settings."
                    lastErrorMessage = nil
                }
                return
            }
        }
        if updateMessaging {
            lastErrorMessage = "Unable to open System Settings."
        }
    }

    private func startAtLogonLaunchAgentPlist() -> String {
        let appPath = Bundle.main.bundlePath
        let escapedAppPath = xmlEscaped(appPath)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(BootstrapService.startAtLogonLaunchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>-g</string>
                <string>-a</string>
                <string>\(escapedAppPath)</string>
                <string>--args</string>
                <string>\(TilePilotLaunchPolicy.loginLaunchArgument)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private func writeStartAtLogonLaunchAgent() throws {
        let fm = FileManager.default
        let launchAgentsDirectory = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try fm.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try startAtLogonLaunchAgentPlist().write(
            to: startAtLogonLaunchAgentURL(),
            atomically: true,
            encoding: .utf8
        )
    }

    private func startAtLogonLaunchAgentURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(BootstrapService.startAtLogonLaunchAgentFileName)
    }

    private func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func applyManagedHelperOperationResult(_ result: ManagedHelperOperationResult) {
        managedHelperInstallState = result.installState
        prependCommandLogs(result.commandLogs.reversed())
        if let errorMessage = result.errorMessage {
            lastErrorMessage = errorMessage
            lastActionMessage = nil
        } else {
            lastActionMessage = result.successMessage ?? "TilePilot yabai/skhd components updated."
            lastErrorMessage = nil
        }
    }

    private func scheduleSetupRefreshAfterExternalHandoff(delaySeconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            await self?.refreshBootstrapSetup()
            await self?.refreshDoctor()
        }
    }
}
