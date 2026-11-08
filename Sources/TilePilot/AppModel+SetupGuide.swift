import Foundation

@MainActor
extension AppModel {
    private var setupGuideItemsByID: [String: SetupCheckItem] {
        Dictionary(uniqueKeysWithValues: setupChecklistItems.map { ($0.id, $0) })
    }

    var missionControlChecklistItems: [MissionControlChecklistItem] {
        buildMissionControlChecklistItems(from: doctorSnapshot?.missionControlChecks ?? [])
    }

    var setupGuideSteps: [SetupGuideStep] {
        let capabilityByKey = Dictionary(uniqueKeysWithValues: (doctorSnapshot?.capabilities ?? []).map { ($0.key, $0) })
        let missionControlChecks = doctorSnapshot?.missionControlChecks ?? []

        let yabaiBinarySetup = setupGuideItemsByID["yabai-binary"]
        let skhdBinarySetup = setupGuideItemsByID["skhd-binary"]
        let yabaiServiceSetup = setupGuideItemsByID["helper-service-yabai"]
        let skhdServiceSetup = setupGuideItemsByID["helper-service-skhd"]
        let startAtLogonSetup = setupGuideItemsByID["start-at-logon"]
        let accessibilitySetup = setupGuideItemsByID["accessibility-permission"]
        let bundledHelpersSetup = setupGuideItemsByID["bundled-helpers"]

        let helperInstallStatus = mergedGuideStatus([
            mappedGuideStatus(from: yabaiBinarySetup?.state),
            mappedGuideStatus(from: skhdBinarySetup?.state),
            mappedGuideStatus(from: capabilityByKey["yabai-binary"]?.status),
            mappedGuideStatus(from: capabilityByKey["skhd-binary"]?.status),
        ])

        let helperDaemonStatus = mergedGuideStatus([
            mappedGuideStatus(from: yabaiServiceSetup?.state),
            mappedGuideStatus(from: skhdServiceSetup?.state),
            mappedGuideStatus(from: capabilityByKey["yabai-daemon"]?.status),
            mappedGuideStatus(from: capabilityByKey["skhd-daemon"]?.status),
        ])
        let yabaiQueryStatus = mappedGuideStatus(from: capabilityByKey["yabai-query"]?.status)
        let helperServicesStatus = mergedGuideStatus([
            helperDaemonStatus,
            mappedGuideStatus(from: capabilityByKey["yabai-query"]?.status),
        ])
        let helperDaemonsRunning = helperDaemonStatus == .good
        let windowControlNeedsStart = !helperDaemonsRunning
        let windowControlNeedsQueryConfirmation = helperDaemonsRunning && yabaiQueryStatus != .good
        let startFailureAdvice = windowControlNeedsStart
            ? HelperStartFailureDiagnosis.advice(for: windowControlStartFailures)
            : nil
        // yabai quits at launch while Displays have separate Spaces is off.
        let separateSpacesLooksOff = missionControlChecks.contains { $0.key == "spans-displays" && $0.status == .warning }
        let separateSpacesBlocksStart = windowControlNeedsStart
            && (separateSpacesLooksOff || windowControlStartFailures.contains { $0.reason == .separateSpacesOff })
        let startSecondaryActions: [SystemCheckAction] = (separateSpacesBlocksStart ? [.openMissionControlSettings] : [])
            + [.openAccessibilitySettings, .recheck]

        let accessibilityStatus = mergedGuideStatus([
            mappedGuideStatus(from: accessibilitySetup?.state),
            mappedGuideStatus(from: capabilityByKey["accessibility"]?.status),
        ], defaultStatus: .notice)

        let startAtLogonStatus = mappedGuideStatus(from: startAtLogonSetup?.state) ?? .notice
        let screenRecordingOn = megamapScreenRecordingAuthorized

        let missionControlStatus: SystemCheckStatus
        if missionControlChecks.contains(where: { $0.status == .warning }) {
            missionControlStatus = .warning
        } else if missionControlChecks.isEmpty || missionControlChecks.contains(where: { $0.status == .unknown }) {
            missionControlStatus = .notice
        } else {
            missionControlStatus = .good
        }

        return [
            SetupGuideStep(
                kind: .installHelpers,
                category: .essential,
                title: "Prepare Window Control",
                summary: helperInstallStatus == .good ? "TilePilot has installed its local yabai/skhd components." : "TilePilot is still preparing the local components it uses for window control and shortcuts.",
                whyItMatters: "TilePilot uses yabai to read and move windows/desktops. It uses skhd to listen for global keyboard shortcuts. Both run as local user services managed by TilePilot.",
                whatToDo: bundledHelpersSetup == nil
                    ? "TilePilot is still checking this Mac. This takes a few seconds."
                    : (bundledHelpersSetup?.state == .installed
                        ? "TilePilot normally does this automatically on first launch. If this step stays incomplete, retry the component install."
                        : "Use the packaged TilePilot app from /Applications. This build does not include the local yabai/skhd components."),
                detail: firstNonEmptyGuideDetail([
                    bundledHelpersSetup?.detail,
                    yabaiBinarySetup?.detail,
                    skhdBinarySetup?.detail,
                    capabilityByKey["yabai-binary"]?.message,
                    capabilityByKey["skhd-binary"]?.message,
                ]),
                verificationText: "TilePilot will recheck component installation automatically.",
                status: helperInstallStatus,
                isBlocking: true,
                isSkippable: true,
                primaryAction: helperInstallStatus == .good || bundledHelpersSetup?.state != .installed ? nil : .installDependencies,
                secondaryActions: [.recheck]
            ),
            SetupGuideStep(
                kind: .startHelperServices,
                category: .essential,
                title: helperServicesStatus == .good ? "Window Control Running" : (windowControlNeedsStart ? "Start Window Control" : "Confirm Window Control"),
                summary: helperServicesStatus == .good
                    ? "Window control and shortcut services are running."
                    : (startFailureAdvice?.problem ?? (windowControlNeedsStart
                        ? "TilePilot installed yabai and skhd. Start them when you are ready; macOS will then ask you to allow them in Accessibility."
                        : "yabai and skhd are running. TilePilot is waiting for yabai to answer window-state queries.")),
                whyItMatters: "yabai is the window-control service. skhd is the shortcut listener. macOS may ask you to allow these entries in Accessibility because they need to observe and move windows.",
                whatToDo: startFailureAdvice?.fix ?? (windowControlNeedsStart
                    ? "Click Start Window Control. macOS then shows two prompts in a row, one for yabai and one for skhd. Click Open System Settings on the first; either button is fine on the second because Settings is already open. Turn on yabai and skhd, then click Start Window Control again."
                    : "Wait a few seconds. If macOS shows an Accessibility prompt for yabai, approve that exact entry, then use Recheck."),
                detail: firstNonEmptyGuideDetail([
                    separateSpacesBlocksStart && startFailureAdvice == nil
                        ? "Displays have separate Spaces looks turned off. yabai will not start until it is on: turn it on in System Settings > Desktop & Dock > Mission Control, then log out and back in."
                        : nil,
                    windowControlNeedsQueryConfirmation ? "The helper services are already running; TilePilot is only waiting for the yabai query check to pass." : nil,
                    helperServicesStatus == .good ? nil : "No Screen Recording permission is needed here. Screen Recording is only for optional MegaMap screenshots.",
                    yabaiServiceSetup?.detail,
                    skhdServiceSetup?.detail,
                    capabilityByKey["yabai-daemon"]?.message,
                    capabilityByKey["skhd-daemon"]?.message,
                    capabilityByKey["yabai-query"]?.message,
                ]),
                verificationText: "TilePilot checks again a few seconds after each start and names the reason if yabai or skhd stops.",
                status: helperServicesStatus,
                isBlocking: true,
                isSkippable: true,
                primaryAction: helperServicesStatus == .good ? nil : (windowControlNeedsStart ? .startYabai : .recheck),
                secondaryActions: helperServicesStatus == .good ? [] : startSecondaryActions
            ),
            SetupGuideStep(
                kind: .accessibility,
                category: .featureOptional,
                title: "Accessibility Access (Optional)",
                summary: accessibilityStatus == .good ? "TilePilot Accessibility access is already granted." : "Accessibility is optional during setup. Review it later only if macOS prompts, helper startup fails with a permission error, or focus fallbacks do not work.",
                whyItMatters: "TilePilot can use Accessibility for bring-to-front/focus fallbacks. Core helper installation and startup should not wait on this unless macOS explicitly reports a permission failure.",
                whatToDo: "Continue setup now. If macOS shows TilePilot, yabai, or skhd in Accessibility later, enable only the entries needed for the feature you are using.",
                detail: firstNonEmptyGuideDetail([
                    accessibilityStatus == .good ? nil : "Not required for MegaMap screenshots. Not required just to complete initial setup.",
                    accessibilitySetup?.detail,
                    capabilityByKey["accessibility"]?.message,
                ]),
                verificationText: "You can come back to this from System if a feature later needs it.",
                status: accessibilityStatus == .good ? .good : .notice,
                isBlocking: false,
                isSkippable: true,
                primaryAction: nil,
                secondaryActions: accessibilityStatus == .good ? [] : [.requestAccessibilityAccess, .openAccessibilitySettings, .recheck]
            ),
            SetupGuideStep(
                kind: .startAtLogon,
                category: .recommended,
                title: "Start TilePilot at Login",
                summary: startAtLogonStatus == .good ? "TilePilot is configured to launch at login." : "TilePilot is easier to rely on when it starts automatically after sign-in.",
                whyItMatters: "TilePilot is a menu bar app. Starting it automatically avoids a dead-looking desktop after login.",
                whatToDo: "Enable TilePilot at login, or open Login Items if you want to review it manually.",
                detail: firstNonEmptyGuideDetail([
                    startAtLogonSetup?.detail,
                ]),
                verificationText: "TilePilot will recheck the launch agent automatically.",
                status: startAtLogonStatus,
                isBlocking: false,
                isSkippable: true,
                primaryAction: startAtLogonStatus == .good ? nil : .enableStartAtLogon,
                secondaryActions: [.openLoginItemsSettings, .recheck]
            ),
            SetupGuideStep(
                kind: .screenRecording,
                category: .featureOptional,
                title: "Screen Recording for MegaMap",
                summary: screenRecordingOn
                    ? "Screen Recording is on. MegaMap shows real screenshots of your desktops."
                    : "Turn this on only if you want MegaMap to show real screenshots of your desktops. Without it, MegaMap draws each desktop as a wireframe with app icons.",
                whyItMatters: "MegaMap is the full-screen map of every desktop (Open MegaMap in the menu bar). Screen Recording lets it show what each desktop really looks like, and lets the System Bar show the real menu bar icons. Screenshots stay in memory and are never saved to disk.",
                whatToDo: "Click Enable Screen Recording. If macOS asks, choose Open System Settings, then turn on TilePilot under Screen Recording. If macOS offers Quit & Reopen, accept it.",
                detail: screenRecordingOn ? nil : "Not using MegaMap? Skip this. You can turn it on later from MegaMap or the System tab.",
                verificationText: "TilePilot rechecks when you come back from System Settings.",
                status: screenRecordingOn ? .good : .notice,
                isBlocking: false,
                isSkippable: true,
                primaryAction: screenRecordingOn ? nil : .requestScreenRecordingAccess,
                secondaryActions: screenRecordingOn ? [] : [.openScreenRecordingSettings, .recheck]
            ),
            SetupGuideStep(
                kind: .missionControl,
                category: .featureOptional,
                title: "Review Mission Control Settings",
                summary: missionControlStatus == .good
                    ? "Mission Control settings look compatible."
                    : (separateSpacesLooksOff
                        ? "yabai needs Displays have separate Spaces turned on. The other Mission Control settings only affect desktop navigation."
                        : "Mission Control settings only affect desktop-navigation reliability. They are not required to finish setup."),
                whyItMatters: "Desktop scrub and some desktop-navigation previews work best when desktop ordering and display grouping are predictable.",
                whatToDo: missionControlWhatToDo(missionControlChecks),
                detail: missionControlGuideDetail(missionControlChecks),
                verificationText: "Review this later only if desktop navigation behaves unpredictably. If you change Displays have separate Spaces, macOS may ask you to log out first.",
                status: missionControlStatus,
                isBlocking: false,
                isSkippable: true,
                primaryAction: missionControlStatus == .good ? nil : .openMissionControlSettings,
                secondaryActions: missionControlStatus == .good ? [] : [.openMissionControlKeyboardShortcuts, .recheck]
            ),
        ]
    }

    var incompleteSetupGuideSteps: [SetupGuideStep] {
        setupGuideSteps.filter { !$0.isSatisfied && $0.category != .featureOptional }
    }

    var incompleteEssentialSetupGuideSteps: [SetupGuideStep] {
        setupGuideSteps.filter { $0.category == .essential && !$0.isSatisfied }
    }

    var hasIncompleteEssentialSetupGuideSteps: Bool {
        !incompleteEssentialSetupGuideSteps.isEmpty
    }

    /// Continue also walks through later optional steps, so the guide reaches Screen Recording before offering Done.
    func setupGuideCanContinue(from kind: SetupGuideStepKind) -> Bool {
        !incompleteSetupGuideSteps.isEmpty
            || setupGuideSteps.drop(while: { $0.kind != kind }).dropFirst().contains { !$0.isSatisfied }
    }

    var currentSetupGuideStep: SetupGuideStep? {
        let steps = setupGuideSteps
        guard !steps.isEmpty else { return nil }
        if let selectedKind = setupGuidePresentationState.selectedStepKind,
           let selected = steps.first(where: { $0.kind == selectedKind }) {
            return selected
        }
        return incompleteSetupGuideSteps.first ?? steps.first
    }

    var setupGuideCompletionTitle: String {
        hasIncompleteEssentialSetupGuideSteps ? "TilePilot still needs setup" : "TilePilot is ready"
    }

    var setupGuideCompletionDetail: String {
        if let current = currentSetupGuideStep, !current.isSatisfied {
            return current.summary
        }
        if incompleteSetupGuideSteps.isEmpty {
            return "All required steps are complete. Optional permissions can still be reviewed later from System or Guided Setup."
        }
        return "The essential setup is complete. Optional and recommended steps can still improve how TilePilot works."
    }

    func presentSetupGuide(source: SetupGuidePresentationSource = .manual, startingAt stepKind: SetupGuideStepKind? = nil) {
        acknowledgeInitialStatusIfNeeded()
        if source == .automatic, !hasIncompleteEssentialSetupGuideSteps {
            setupGuidePresentationState = .hidden
            return
        }
        let selected = stepKind ?? preferredStartingSetupGuideStep(for: source)?.kind
        // A genuine first launch starts with the feature tour so the user
        // learns what TilePilot does before any permission is discussed.
        let welcomeIndex: Int? = source == .firstLaunch ? 0 : nil
        setupGuidePresentationState = SetupGuidePresentationState(
            isPresented: true,
            source: source,
            selectedStepKind: selected,
            welcomePageIndex: welcomeIndex
        )
    }

    var setupGuideWelcomePage: SetupGuideWelcomePage? {
        guard let index = setupGuidePresentationState.welcomePageIndex else { return nil }
        return SetupGuideWelcomeContent.page(at: index)
    }

    var setupGuideWelcomeIsLastPage: Bool {
        guard let index = setupGuidePresentationState.welcomePageIndex else { return true }
        return SetupGuideWelcomeContent.isLastPage(index)
    }

    func advanceSetupGuideWelcomePage() {
        guard let index = setupGuidePresentationState.welcomePageIndex else { return }
        if SetupGuideWelcomeContent.isLastPage(index) {
            finishSetupGuideWelcomeTour()
        } else {
            setupGuidePresentationState.welcomePageIndex = index + 1
        }
    }

    func rewindSetupGuideWelcomePage() {
        guard let index = setupGuidePresentationState.welcomePageIndex, index > 0 else { return }
        setupGuidePresentationState.welcomePageIndex = index - 1
    }

    func finishSetupGuideWelcomeTour() {
        setupGuidePresentationState.welcomePageIndex = nil
        if setupGuidePresentationState.selectedStepKind == nil {
            setupGuidePresentationState.selectedStepKind = preferredStartingSetupGuideStep(for: setupGuidePresentationState.source)?.kind
        }
    }

    func replaySetupGuideWelcomeTour() {
        guard setupGuidePresentationState.isPresented else { return }
        setupGuidePresentationState.welcomePageIndex = 0
    }

    func dismissSetupGuide() {
        // A first-launch guide counts too; otherwise the next refresh reopens it as automatic.
        if setupGuidePresentationState.source != .manual, hasIncompleteEssentialSetupGuideSteps {
            hasDismissedAutomaticSetupGuideThisSession = true
        }
        setupGuidePresentationState = .hidden
    }

    func continueSetupGuide() {
        if let next = nextIncompleteSetupGuideStep(after: setupGuidePresentationState.selectedStepKind) {
            setupGuidePresentationState.selectedStepKind = next.kind
        } else {
            dismissSetupGuide()
        }
    }

    func selectSetupGuideStep(_ kind: SetupGuideStepKind) {
        setupGuidePresentationState.selectedStepKind = kind
    }

    func maybePresentSetupGuideAutomatically() {
        guard shouldAutoPresentSetupGuide else { return }
        presentSetupGuide(source: .automatic)
    }

    func scheduleAutomaticSetupGuideAfterStartupGrace() {
        guard automaticSetupGuideStartupTask == nil,
              !automaticSetupGuideStartupGraceElapsed else {
            return
        }

        if isInitialSetupLaunchSession {
            automaticSetupGuideStartupGraceElapsed = true
            presentSetupGuide(source: .firstLaunch)
            return
        }

        automaticSetupGuideStartupTask = Task { [weak self] in
            guard let self else { return }

            // launchd can report the services before yabai's query socket is ready.
            // Keep that normal boot race quiet while rechecking for up to ten seconds.
            for delaySeconds in [2.0, 2.0, 3.0, 3.0] {
                do {
                    try await Task.sleep(for: .seconds(delaySeconds))
                } catch {
                    return
                }

                guard !self.windowControlReadyForSetup else { break }
                await self.refreshBootstrapSetup()
                await self.refreshDoctor()
            }

            guard !Task.isCancelled else { return }
            self.automaticSetupGuideStartupGraceElapsed = true
            self.automaticSetupGuideStartupTask = nil
            self.refreshSetupGuidePresentationAfterStateChange()
        }
    }

    func refreshSetupGuidePresentationAfterStateChange() {
        if setupGuidePresentationState.isPresented {
            // Never mutate or auto-hide the guide while the feature tour is
            // showing; background rechecks should not yank pages away.
            if setupGuidePresentationState.welcomePageIndex != nil {
                return
            }
            if setupGuidePresentationState.source == .automatic, !hasIncompleteEssentialSetupGuideSteps {
                setupGuidePresentationState = .hidden
                return
            }

            if let selectedKind = setupGuidePresentationState.selectedStepKind,
               let selectedStep = setupGuideSteps.first(where: { $0.kind == selectedKind }) {
                if setupGuidePresentationState.source == .automatic,
                   selectedStep.isSatisfied,
                   let next = preferredStartingSetupGuideStep(for: .automatic) {
                    setupGuidePresentationState.selectedStepKind = next.kind
                }
                return
            }

            setupGuidePresentationState.selectedStepKind = preferredStartingSetupGuideStep(for: setupGuidePresentationState.source)?.kind
            return
        }

        maybePresentSetupGuideAutomatically()
    }

    private var shouldAutoPresentSetupGuide: Bool {
        SetupGuideAutomaticPresentationPolicy.shouldPresent(
            startupGraceElapsed: automaticSetupGuideStartupGraceElapsed,
            hasBootstrapSnapshot: bootstrapSnapshot != nil,
            hasDoctorSnapshot: doctorSnapshot != nil,
            hasIncompleteEssentialSteps: hasIncompleteEssentialSetupGuideSteps,
            dismissedThisSession: hasDismissedAutomaticSetupGuideThisSession
        )
    }

    private func preferredStartingSetupGuideStep(for source: SetupGuidePresentationSource) -> SetupGuideStep? {
        switch source {
        case .firstLaunch:
            return incompleteEssentialSetupGuideSteps.first ?? incompleteSetupGuideSteps.first ?? setupGuideSteps.first
        case .automatic:
            return incompleteEssentialSetupGuideSteps.first ?? incompleteSetupGuideSteps.first
        case .manual:
            return incompleteSetupGuideSteps.first ?? setupGuideSteps.first
        }
    }

    private func nextIncompleteSetupGuideStep(after kind: SetupGuideStepKind?) -> SetupGuideStep? {
        let steps = setupGuideSteps
        let unresolved = steps.filter { !$0.isSatisfied }
        guard !unresolved.isEmpty else { return nil }
        guard let kind,
              let selectedIndex = steps.firstIndex(where: { $0.kind == kind }) else {
            return unresolved.first
        }

        if selectedIndex + 1 < steps.count,
           let next = steps[(selectedIndex + 1)...].first(where: { !$0.isSatisfied }) {
            return next
        }

        return unresolved.first
    }

    private func mappedGuideStatus(from setupState: SetupCheckState?) -> SystemCheckStatus? {
        guard let setupState else { return nil }
        switch setupState {
        case .installed:
            return .good
        case .missing:
            return .error
        case .warning:
            return .warning
        case .unknown:
            return .notice
        }
    }

    private func mappedGuideStatus(from capabilityStatus: CapabilityStatus?) -> SystemCheckStatus? {
        guard let capabilityStatus else { return nil }
        switch capabilityStatus {
        case .available:
            return .good
        case .unknown:
            return .notice
        case .degraded:
            return .warning
        case .unsupported, .blocked:
            return .error
        }
    }

    private func mergedGuideStatus(_ statuses: [SystemCheckStatus?], defaultStatus: SystemCheckStatus = .error) -> SystemCheckStatus {
        statuses.compactMap { $0 }.max(by: { $0.severityRank < $1.severityRank }) ?? defaultStatus
    }

    private func firstNonEmptyGuideDetail(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { continue }
            return trimmed
        }
        return nil
    }

    private func missionControlGuideDetail(_ checks: [MissionControlCheck]) -> String {
        if checks.isEmpty {
            return "TilePilot has not verified these settings yet. Use the checklist and confirm both values manually."
        }

        var notes: [String] = []

        if let mruSpaces = checks.first(where: { $0.key == "mru-spaces" }) {
            switch mruSpaces.status {
            case .warning:
                notes.append("Automatically rearrange Spaces based on most recent use looks enabled right now.")
            case .unknown:
                notes.append("TilePilot could not verify Automatically rearrange Spaces based on most recent use.")
            case .pass:
                break
            }
        }

        if let spansDisplays = checks.first(where: { $0.key == "spans-displays" }) {
            switch spansDisplays.status {
            case .warning:
                notes.append("Displays have separate Spaces may be turned off right now.")
            case .unknown:
                notes.append("TilePilot could not verify Displays have separate Spaces.")
            case .pass:
                break
            }
        }

        if notes.isEmpty {
            return "The checklist matches the expected Mission Control values."
        }

        return notes.joined(separator: " ")
    }

    private func missionControlWhatToDo(_ checks: [MissionControlCheck]) -> String {
        if checks.contains(where: { $0.status == .unknown }) {
            return "Open Mission Control settings and match the checklist below. TilePilot could not verify one or both values automatically, so manual review is required."
        }

        return "Open Mission Control settings and match the checklist below."
    }
}
