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

    var setupStateNeedsAttention: Bool {
        primarySetupAction != .ready
    }
}
