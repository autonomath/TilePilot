import Foundation

@MainActor
extension AppModel {
    private var setupItemsByID: [String: SetupCheckItem] {
        Dictionary(uniqueKeysWithValues: setupChecklistItems.map { ($0.id, $0) })
    }

    private var helpersInstalledForSetup: Bool {
        setupItemInstalled("yabai-binary") && setupItemInstalled("skhd-binary")
    }

    var helperServicesRunningForSetup: Bool {
        setupItemInstalled("helper-service-yabai") && setupItemInstalled("helper-service-skhd")
    }

    var yabaiQueryReadyForSetup: Bool {
        doctorSnapshot?.capabilities.first(where: { $0.key == "yabai-query" })?.status == .available
    }

    var windowControlReadyForSetup: Bool {
        helperServicesRunningForSetup && yabaiQueryReadyForSetup
    }

    var managedHelpersInstalledButNotStartedForSetup: Bool {
        guard ManagedHelperService.shared.hasManagedHelperInstall() else { return false }
        guard !helperServicesRunningForSetup else { return false }
        let installState = managedHelperInstallState ?? ManagedHelperService.shared.loadInstallState()
        return installState?.launchAgentsInstalled != true
    }

    var primarySetupAction: SetupNextAction {
        if doctorSnapshot == nil || bootstrapSnapshot == nil {
            return .recheck
        }
        if !helpersInstalledForSetup {
            return .installHelpers
        }
        if !helperServicesRunningForSetup {
            return .startHelperServices
        }
        return .ready
    }

    var primarySetupActionLabel: String {
        primarySetupAction.buttonTitle
    }

    var primarySetupActionDetail: String {
        switch primarySetupAction {
        case .installHelpers:
            if !setupItemInstalled("bundled-helpers") {
                return "This TilePilot build does not include the local yabai/skhd components. Use the packaged app from /Applications."
            }
            return "TilePilot normally installs its local yabai/skhd components automatically. Use this only to retry if that did not finish."
        case .reviewAccessibility:
            return "Optional. Review Accessibility only if macOS prompts for TilePilot, yabai, or skhd, or if focus/bring-to-front fallbacks do not work."
        case .startHelperServices:
            return "TilePilot installed yabai and skhd. Start window control when you are ready; macOS will ask you to allow yabai and skhd in Accessibility. Approve the exact named entries and recheck."
        case .recheck:
            return "TilePilot is still checking this Mac. Recheck setup if the status looks stale."
        case .ready:
            return "TilePilot window control looks ready."
        }
    }

    var primarySetupSummaryLine: String {
        switch primarySetupAction {
        case .ready:
            if let snapshot = bootstrapSnapshot {
                return "Ready · \(snapshot.generatedAt.formatted(date: .omitted, time: .standard))"
            }
            return "Ready"
        case .recheck:
            return "Setup scan needed"
        default:
            return "\(primarySetupAction.summaryTitle) · \(primarySetupActionDetail)"
        }
    }

    var setupRequiredRows: [SystemCheckRow] {
        let requiredIDs: Set<String> = [
            "yabai-installed",
            "skhd-installed",
            "yabai-running",
            "skhd-running",
        ]
        return systemCheckRows.filter { requiredIDs.contains($0.id) }
    }

    var setupOptionalRows: [SystemCheckRow] {
        let optionalIDs: Set<String> = [
            "start-at-logon",
            "accessibility",
            "mission-control",
        ]
        return systemCheckRows.filter { optionalIDs.contains($0.id) }
    }

    var setupBlockingRows: [SystemCheckRow] {
        let blockingStatuses: Set<SystemCheckStatus> = [.warning, .error, .notice]
        return setupRequiredRows.filter { blockingStatuses.contains($0.status) }
    }

    var setupOptionalRowsNeedingAttention: [SystemCheckRow] {
        let attentionStatuses: Set<SystemCheckStatus> = [.warning, .notice, .error]
        return setupOptionalRows.filter { attentionStatuses.contains($0.status) }
    }

    var isPrimarySetupActionInFlight: Bool {
        switch primarySetupAction {
        case .installHelpers:
            return isLaunchingSetupInstaller
        case .reviewAccessibility:
            return false
        case .startHelperServices:
            return isLaunchingSetupInstaller
        case .recheck:
            return isRefreshing || isRefreshingBootstrap
        case .ready:
            return false
        }
    }

    func performPrimarySetupAction() {
        performSetupAction(primarySetupAction)
    }

    func performSetupAction(_ action: SetupNextAction) {
        switch action {
        case .installHelpers:
            installManagedHelpers()
        case .reviewAccessibility:
            presentSetupGuide(source: .manual, startingAt: .accessibility)
        case .startHelperServices:
            startWindowControlBestEffort()
        case .recheck:
            Task { [weak self] in
                guard let self else { return }
                await self.refreshBootstrapSetup()
                await self.refreshDoctor()
            }
        case .ready:
            lastActionMessage = "TilePilot already looks ready."
            lastErrorMessage = nil
        }
    }

    private func setupItemInstalled(_ id: String) -> Bool {
        setupItemsByID[id]?.state == .installed
    }

    var setupDisplayRows: [SystemCheckRow] {
        setupRequiredRows + setupOptionalRows
    }

    var setupStateNeedsAttention: Bool {
        primarySetupAction != .ready
    }
}
