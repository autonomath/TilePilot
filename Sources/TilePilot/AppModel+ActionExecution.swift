import Darwin
import Foundation

extension AppModel {
    private func shortcutCommandTimeout(for commandText: String) -> TimeInterval {
        let normalized = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains("~/.config/yabai/scripts/") || normalized.contains("/.config/yabai/scripts/") {
            return 15.0
        }
        return 3.0
    }

    func performTilePilotAction(_ actionID: TilePilotActionID) {
        guard activeActionID == nil else { return }
        let availability = actionAvailability(for: actionID)
        guard availability.enabled else {
            let message = availability.disabledReason ?? "This action is unavailable right now."
            actionsLastErrorMessage = message
            actionsLastActionMessage = nil
            lastErrorMessage = message
            lastActionMessage = nil
            return
        }

        actionsLastErrorMessage = nil
        actionsLastActionMessage = nil

        Task { [weak self] in
            guard let self else { return }
            await self.runTilePilotAction(actionID)
        }
    }

    func runShortcutCommand(_ commandText: String, shortcutLabel: String) {
        Task { [weak self] in
            guard let self else { return }
            let timeout = self.shortcutCommandTimeout(for: commandText)
            let result = await self.doctorService.runSupportCommand(
                ShellCommand("/bin/zsh", ["-lc", commandText], timeout: timeout)
            )
            await MainActor.run {
                let logEntry = CommandLogEntry(
                    id: UUID(),
                    command: "shortcut: \(shortcutLabel)",
                    startedAt: result.startedAt,
                    endedAt: result.endedAt,
                    durationMs: result.durationMs,
                    exitStatus: result.exitStatus,
                    stdoutSnippet: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160).description,
                    stderrSnippet: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160).description,
                    errorType: result.errorType
                )
                self.commandLogs = Array(([logEntry] + self.commandLogs).prefix(200))

                if result.isSuccess {
                    self.lastActionMessage = "Ran shortcut: \(shortcutLabel)"
                    self.lastErrorMessage = nil
                    Task {
                        await self.refreshLiveState()
                    }
                } else {
                    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.errorType == .timeout {
                        self.lastErrorMessage = "Shortcut timed out after \(Int(timeout))s: \(shortcutLabel)"
                    } else {
                        self.lastErrorMessage = stderr.isEmpty ? "Shortcut command failed: \(shortcutLabel)" : "Shortcut failed: \(stderr)"
                    }
                    self.lastActionMessage = nil
                }
            }
        }
    }

    func runSupportCommand(_ command: ShellCommand, successMessage: String) {
        guard !isRefreshing else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.doctorService.runSupportCommand(command)
            await MainActor.run {
                let logEntry = CommandLogEntry(
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
                self.commandLogs = Array(([logEntry] + self.commandLogs).prefix(200))
                if result.isSuccess {
                    self.lastActionMessage = successMessage
                    self.lastErrorMessage = nil
                    Task {
                        await self.refreshLiveState()
                        await self.refreshDoctor()
                        await self.refreshBootstrapSetup()
                        await self.refreshWindowBehaviorConfig()
                    }
                } else {
                    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if result.command.contains("yabai"), stderr.contains("could not connect") {
                        self.lastErrorMessage = "yabai is not running. Start yabai, then try again."
                    } else if result.command.contains("yabai"), (stderr.contains("no such file") || stderr.contains("not found")) {
                        self.lastErrorMessage = "yabai is not installed or not available in PATH."
                    } else {
                        self.lastErrorMessage = "Command failed: \(result.command)"
                    }
                    self.lastActionMessage = nil
                }
            }
        }
    }

    var actionCards: [TilePilotActionCard] {
        TilePilotActionID.allCases
            .filter { $0 != .browserReliefPlaceholder }
            .map { actionID in
                let meta = TilePilotActionCatalog.meta(for: actionID)
                let availability = actionAvailability(for: actionID)
                return TilePilotActionCard(
                    id: actionID,
                    title: meta.title,
                    subtitle: meta.subtitle,
                    category: meta.category,
                    requiredCapabilities: meta.requiredCapabilities,
                    enabled: availability.enabled,
                    disabledReason: availability.disabledReason
                )
            }
    }

    var quickActionCards: [TilePilotActionCard] {
        actionCards.filter { ["Layouts", "Window"].contains($0.category) && $0.id != .browserReliefPlaceholder }
    }

    func runBestEffortSkhdRestart(afterConfigChange: Bool) async {
        let failure = await requestRunningSkhdReload()
        // Doctor refresh clears generic action feedback. Publish the save and
        // activation result afterwards so a failed reload remains visible.
        await refreshDoctor()
        if let failure {
            if afterConfigChange {
                lastActionMessage = "Config saved. Shortcuts could not be activated."
            }
            lastErrorMessage = failure
        } else {
            if afterConfigChange {
                lastActionMessage = "Config saved and shortcut reload requested."
            }
            lastErrorMessage = nil
        }
    }

    func runBestEffortSkhdRestartAfterRawFileSave() async {
        if let failure = await requestRunningSkhdReload() {
            filesLastActionMessage = "Saved file. Shortcuts could not be activated."
            filesLastErrorMessage = failure
        } else {
            filesLastActionMessage = "Saved file and shortcut reload requested."
            filesLastErrorMessage = nil
        }
    }

    private func requestRunningSkhdReload() async -> String? {
        // skhd's own reload relies on a /tmp PID file, which may have been
        // removed while the service is still running. Locate only this user's
        // existing daemon and never start a helper as a side effect of saving.
        let lookup = await doctorService.runSupportCommand(
            ShellCommand("/usr/bin/pgrep", ["-x", "-u", String(getuid()), "skhd"], timeout: 2.0)
        )
        appendCommandLog(from: lookup)
        if lookup.exitStatus == 1, lookup.errorType == .nonZeroExit,
           lookup.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SkhdReloadTargetError.notRunning.localizedDescription
        }
        guard lookup.isSuccess else {
            return "Could not find the running shortcut service. Open System and recheck skhd."
        }
        let pid: Int32
        switch SkhdReloadTarget.resolve(pgrepOutput: lookup.stdout) {
        case .success(let target): pid = target
        case .failure(let error): return error.localizedDescription
        }

        let result = await doctorService.runSupportCommand(
            ShellCommand("/bin/kill", ["-USR1", String(pid)], timeout: 2.0)
        )
        appendCommandLog(from: result)
        guard result.isSuccess else {
            let details = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return details.isEmpty
                ? "Could not reload shortcuts. Open System and recheck skhd."
                : "Could not reload shortcuts: \(trimForUI(details))"
        }
        return nil
    }

    func appendCommandLog(from result: CommandResult) {
        let logEntry = CommandLogEntry(
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
        commandLogs = Array(([logEntry] + commandLogs).prefix(200))
    }

    func prependCommandLogs(_ logs: [CommandLogEntry]) {
        guard !logs.isEmpty else { return }
        commandLogs = Array((logs + commandLogs).prefix(200))
    }

    func actionCard(for actionID: TilePilotActionID) -> TilePilotActionCard? {
        actionCards.first(where: { $0.id == actionID })
    }

    func actionCard(forShortcut entry: ShortcutEntry) -> TilePilotActionCard? {
        guard let actionID = matchingActionID(forShortcutIntentKey: shortcutIntentKey(for: entry)) else { return nil }
        return actionCard(for: actionID)
    }

    private func runTilePilotAction(_ actionID: TilePilotActionID) async {
        activeActionID = actionID
        defer { activeActionID = nil }

        if actionID == .fillWorkArea {
            let outcome = await fillFocusedWindowToWorkArea()
            if outcome.isError {
                actionsLastErrorMessage = outcome.message
                actionsLastActionMessage = nil
                lastErrorMessage = outcome.message
                lastActionMessage = nil
            } else {
                actionsLastActionMessage = outcome.message
                actionsLastErrorMessage = nil
                lastActionMessage = outcome.message
                lastErrorMessage = nil
            }
            return
        }

        let beforeSignature = liveStateSignature()
        let commands = TilePilotActionCatalog.commands(for: actionID)
        guard !commands.isEmpty else {
            actionsLastErrorMessage = "This action is not available yet."
            actionsLastActionMessage = nil
            lastErrorMessage = actionsLastErrorMessage
            lastActionMessage = nil
            return
        }

        for command in commands {
            let result = await doctorService.runSupportCommand(command)
            appendCommandLog(from: result)
            if !result.isSuccess {
                actionsLastErrorMessage = TilePilotActionCatalog.meta(for: actionID).title + " didn’t work."
                if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    actionsLastErrorMessage = TilePilotActionCatalog.failureMessage(for: actionID, commandResult: result)
                }
                actionsLastActionMessage = nil
                lastErrorMessage = actionsLastErrorMessage
                lastActionMessage = nil
                return
            }
        }

        await refreshLiveState()

        let afterSignature = liveStateSignature()
        if beforeSignature != nil, beforeSignature == afterSignature {
            actionsLastActionMessage = "\(TilePilotActionCatalog.meta(for: actionID).title) ran, but nothing visibly changed."
        } else {
            actionsLastActionMessage = "\(TilePilotActionCatalog.meta(for: actionID).title) completed."
        }
        actionsLastErrorMessage = nil
        lastActionMessage = actionsLastActionMessage
        lastErrorMessage = nil
    }

    private func liveStateSignature() -> String? {
        guard let snapshot = liveStateSnapshot else { return nil }
        let focusedWindow = snapshot.windows.first(where: \.focused)?.id ?? -1
        let focusedSpace = snapshot.spaces.first(where: \.focused)?.index ?? -1
        let layouts = snapshot.spaces.map { "\($0.index):\($0.layout ?? "?")" }.joined(separator: ",")
        return [
            snapshot.source.rawValue,
            snapshot.degraded ? "1" : "0",
            String(snapshot.yabaiWindowTotal ?? -1),
            String(snapshot.fallbackWindowTotal ?? -1),
            String(focusedWindow),
            String(focusedSpace),
            layouts,
        ].joined(separator: "|")
    }

    private func actionAvailability(for actionID: TilePilotActionID) -> (enabled: Bool, disabledReason: String?) {
        let meta = TilePilotActionCatalog.meta(for: actionID)

        if actionID == .browserReliefPlaceholder {
            return (false, "This action is not available yet.")
        }

        guard let doctor = doctorSnapshot else {
            return (false, "Open System and run Recheck first.")
        }

        let capabilityByKey = Dictionary(uniqueKeysWithValues: doctor.capabilities.map { ($0.key, $0) })
        for key in meta.requiredCapabilities {
            guard let capability = capabilityByKey[key] else {
                return (false, "Run System Recheck, then try this action.")
            }
            if capability.status == .blocked || capability.status == .unsupported {
                return (false, TilePilotActionCatalog.userFacingDisabledReason(forCapabilityKey: key, capability: capability))
            }
            if key == "yabai-query", capability.status != .available {
                return (false, TilePilotActionCatalog.userFacingDisabledReason(forCapabilityKey: key, capability: capability))
            }
            if key == "yabai-daemon", capability.status != .available {
                return (false, TilePilotActionCatalog.userFacingDisabledReason(forCapabilityKey: key, capability: capability))
            }
            if key == "yabai-binary", capability.status != .available {
                return (false, TilePilotActionCatalog.userFacingDisabledReason(forCapabilityKey: key, capability: capability))
            }
        }

        if meta.requiresLiveState {
            guard let snapshot = liveStateSnapshot else {
                return (false, "Overview is still loading. Try again in a moment.")
            }
            if snapshot.source == .stale {
                return (false, "TilePilot lost the live window view. Open Overview and wait for it to recover.")
            }
        }

        if meta.disableInDegradedMode {
            if let snapshot = liveStateSnapshot, snapshot.degraded {
                return (false, "This layout action is temporarily unavailable because TilePilot is using a reduced-precision view.")
            }
        }

        if activeActionID != nil {
            return (false, "Another action is already running.")
        }

        return (true, nil)
    }
}
