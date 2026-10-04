import Foundation

@MainActor
extension AppModel {
    var coreChecklistItems: [DoctorChecklistItem] {
        checklistItems.filter(\.isCore)
    }

    var setupChecklistItems: [SetupCheckItem] {
        bootstrapSnapshot?.items ?? []
    }

    var setupCoreItems: [SetupCheckItem] {
        setupChecklistItems.filter { ["bundled-helpers", "yabai-binary", "skhd-binary"].contains($0.id) }
    }

    var setupServiceItems: [SetupCheckItem] {
        setupChecklistItems.filter {
            [
                "helper-service-yabai",
                "helper-service-skhd",
                "start-at-logon",
                "accessibility-permission",
            ].contains($0.id)
        }
    }

    var setupSummaryLine: String {
        primarySetupSummaryLine
    }

    var systemCheckRows: [SystemCheckRow] {
        let setupByID = Dictionary(uniqueKeysWithValues: setupChecklistItems.map { ($0.id, $0) })
        let capabilityByKey = Dictionary(uniqueKeysWithValues: (doctorSnapshot?.capabilities ?? []).map { ($0.key, $0) })
        let missionControlChecks = doctorSnapshot?.missionControlChecks ?? []

        let bundledHelpers = setupByID["bundled-helpers"]
        let yabaiBinarySetup = setupByID["yabai-binary"]
        let skhdBinarySetup = setupByID["skhd-binary"]
        let yabaiServiceSetup = setupByID["helper-service-yabai"]
        let skhdServiceSetup = setupByID["helper-service-skhd"]
        let startAtLogonSetup = setupByID["start-at-logon"]
        let accessibilitySetup = setupByID["accessibility-permission"]

        let yabaiBinaryCap = capabilityByKey["yabai-binary"]
        let skhdBinaryCap = capabilityByKey["skhd-binary"]
        let yabaiDaemonCap = capabilityByKey["yabai-daemon"]
        let skhdDaemonCap = capabilityByKey["skhd-daemon"]
        let yabaiQueryCap = capabilityByKey["yabai-query"]
        let accessibilityCap = capabilityByKey["accessibility"]
        let screenRecordingAuthorized = megamapCaptureService.screenRecordingAuthorized()
        var rows: [SystemCheckRow] = []

        let yabaiInstallStatus = mergedSystemStatus([
            mappedSystemStatus(from: yabaiBinarySetup?.state),
            mappedSystemStatus(from: yabaiBinaryCap?.status),
        ])
        rows.append(SystemCheckRow(
            id: "yabai-installed",
            title: "Window Control Component Installed",
            detail: firstDetail(
                yabaiBinaryCap?.message,
                yabaiBinarySetup?.detail,
                bundledHelpers?.detail,
                fallback: "TilePilot uses yabai for desktop and window control. The packaged app installs this automatically."
            ),
            status: yabaiInstallStatus,
            actions: yabaiInstallStatus == .good ? [.recheck] : [.installDependencies, .recheck]
        ))

        let skhdInstallStatus = mergedSystemStatus([
            mappedSystemStatus(from: skhdBinarySetup?.state),
            mappedSystemStatus(from: skhdBinaryCap?.status),
        ])
        rows.append(SystemCheckRow(
            id: "skhd-installed",
            title: "Shortcut Component Installed",
            detail: firstDetail(
                skhdBinaryCap?.message,
                skhdBinarySetup?.detail,
                bundledHelpers?.detail,
                fallback: "TilePilot uses skhd for global keyboard shortcuts. The packaged app installs this automatically."
            ),
            status: skhdInstallStatus,
            actions: skhdInstallStatus == .good ? [.recheck] : [.installDependencies, .recheck]
        ))

        let yabaiRunningStatus = mergedSystemStatus([
            mappedSystemStatus(from: yabaiServiceSetup?.state),
            mappedSystemStatus(from: yabaiDaemonCap?.status),
            mappedSystemStatus(from: yabaiQueryCap?.status),
        ])
        let yabaiRunningActions: [SystemCheckAction]
        if yabaiInstallStatus != .good {
            yabaiRunningActions = [.installDependencies, .recheck]
        } else {
            yabaiRunningActions = yabaiRunningStatus == .good ? [.recheck] : [.startYabai, .restartYabai, .recheck]
        }
        rows.append(SystemCheckRow(
            id: "yabai-running",
            title: "Window Control Running",
            detail: firstDetail(
                yabaiQueryCap?.message,
                yabaiDaemonCap?.message,
                yabaiServiceSetup?.detail,
                fallback: "Start yabai so TilePilot can read and control windows/desktops."
            ),
            status: yabaiRunningStatus,
            actions: yabaiRunningActions
        ))

        let skhdRunningStatus = mergedSystemStatus([
            mappedSystemStatus(from: skhdServiceSetup?.state),
            mappedSystemStatus(from: skhdDaemonCap?.status),
        ])
        let skhdRunningActions: [SystemCheckAction]
        if skhdInstallStatus != .good {
            skhdRunningActions = [.installDependencies, .recheck]
        } else {
            skhdRunningActions = skhdRunningStatus == .good ? [.recheck] : [.startSkhd, .restartSkhd, .recheck]
        }
        rows.append(SystemCheckRow(
            id: "skhd-running",
            title: "Shortcut Listener Running",
            detail: firstDetail(skhdDaemonCap?.message, skhdServiceSetup?.detail, fallback: "Start skhd so TilePilot shortcuts can run."),
            status: skhdRunningStatus,
            actions: skhdRunningActions
        ))

        let startAtLogonStatus = mappedSystemStatus(from: startAtLogonSetup?.state) ?? .notice
        rows.append(SystemCheckRow(
            id: "start-at-logon",
            title: "Start TilePilot at Logon",
            detail: firstDetail(
                startAtLogonSetup?.detail,
                fallback: "Recommended so TilePilot appears in the menu bar after sign-in."
            ),
            status: startAtLogonStatus,
            actions: startAtLogonStatus == .good
                ? [.openLoginItemsSettings, .recheck]
                : [.enableStartAtLogon, .openLoginItemsSettings, .recheck]
        ))

        let rawAccessibilityStatus = mergedSystemStatus([
            mappedSystemStatus(from: accessibilitySetup?.state),
            mappedSystemStatus(from: accessibilityCap?.status),
        ])
        let accessibilityStatus: SystemCheckStatus
        switch rawAccessibilityStatus {
        case .good: accessibilityStatus = .good
        default: accessibilityStatus = .notice
        }
        rows.append(SystemCheckRow(
            id: "accessibility",
            title: "Accessibility Access (Optional)",
            detail: firstDetail(
                accessibilitySetup?.detail,
                accessibilityCap?.message,
                fallback: "Optional during setup. Review only if macOS prompts for TilePilot, yabai, or skhd, or if helper startup reports a permission error."
            ),
            status: accessibilityStatus,
            actions: accessibilityStatus == .good ? [.recheck] : [.requestAccessibilityAccess, .openAccessibilitySettings, .recheck]
        ))

        rows.append(SystemCheckRow(
            id: "screen-recording",
            title: "MegaMap Screenshots (Optional)",
            detail: screenRecordingAuthorized
                ? "Enabled for real MegaMap screenshots."
                : "Needed only for real MegaMap screenshots. Ignore this unless you use MegaMap and want real screenshots instead of the fallback preview.",
            status: screenRecordingAuthorized ? .good : .notice,
            actions: screenRecordingAuthorized
                ? [.recheck]
                : [.openScreenRecordingSettings, .recheck]
        ))

        let missionWarningCount = missionControlChecks.filter { $0.status == .warning }.count
        let missionUnknownCount = missionControlChecks.filter { $0.status == .unknown }.count
        let missionStatus: SystemCheckStatus
        if missionWarningCount > 0 {
            missionStatus = .warning
        } else if missionUnknownCount > 0 || missionControlChecks.isEmpty {
            missionStatus = .notice
        } else {
            missionStatus = .good
        }
        let missionDetail: String
        if missionWarningCount > 0 {
            missionDetail = "Optional. Review the checklist only if desktop navigation or desktop scrub behaves unpredictably."
        } else if missionUnknownCount > 0 {
            missionDetail = "TilePilot could not verify one or both values automatically. You can ignore this unless desktop navigation is unreliable."
        } else if missionControlChecks.isEmpty {
            missionDetail = "Optional manual review for desktop navigation behavior."
        } else {
            missionDetail = "The checklist below matches the expected Mission Control values."
        }
        rows.append(SystemCheckRow(
            id: "mission-control",
            title: "Mission Control Settings",
            detail: missionDetail,
            status: missionStatus,
            actions: missionStatus == .good
                ? [.openMissionControlSettings, .recheck]
                : [.openMissionControlSettings, .openMissionControlKeyboardShortcuts, .recheck]
        ))

        let passiveOptionalRowIDs: Set<String> = [
            "accessibility",
            "screen-recording",
            "mission-control",
            "start-at-logon",
        ]
        return rows.sorted { lhs, rhs in
            let lhsPassiveOptional = passiveOptionalRowIDs.contains(lhs.id)
            let rhsPassiveOptional = passiveOptionalRowIDs.contains(rhs.id)
            if lhsPassiveOptional != rhsPassiveOptional {
                return !lhsPassiveOptional
            }
            if lhs.status.severityRank != rhs.status.severityRank {
                return lhs.status.severityRank > rhs.status.severityRank
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var systemSummaryLine: String {
        switch primarySetupAction {
        case .ready:
            return "Ready"
        case .recheck:
            return "Setup scan needed"
        default:
            return primarySetupAction.summaryTitle
        }
    }

    func performSystemCheckAction(_ action: SystemCheckAction) {
        switch action {
        case .installDependencies:
            performSetupAction(.installHelpers)
        case .startYabai:
            startYabaiBestEffort()
        case .startSkhd:
            startSkhdBestEffort()
        case .runGuidedSetup:
            presentSetupGuide()
        case .enableStartAtLogon:
            enableStartAtLogon()
        case .openLoginItemsSettings:
            openLoginItemsSettings()
        case .openAccessibilitySettings:
            openAccessibilitySettings()
        case .requestAccessibilityAccess:
            requestAccessibilityAccessPrompt()
        case .requestScreenRecordingAccess:
            requestScreenRecordingAccessPrompt()
        case .openScreenRecordingSettings:
            openScreenRecordingSettings()
        case .fixScriptingAddition:
            runScriptingAdditionRepairInTerminal()
        case .openMissionControlSettings:
            openMissionControlSettings()
        case .openMissionControlKeyboardShortcuts:
            openMissionControlKeyboardShortcuts()
        case .restartYabai:
            restartYabaiBestEffort()
        case .restartSkhd:
            restartSkhdBestEffort()
        case .checkForUpdates:
            checkForAppUpdates(manual: true)
        case .openLatestReleasePage:
            openLatestReleasePage()
        case .recheck:
            performSetupAction(.recheck)
        }
    }

    var advancedChecklistItems: [DoctorChecklistItem] {
        checklistItems.filter { !$0.isCore }
    }

    private var checklistItems: [DoctorChecklistItem] {
        var items: [DoctorChecklistItem] = []
        for item in doctorSnapshot?.capabilities ?? [] {
            switch item.key {
            case "yabai-binary":
                items.append(checklist(from: item, title: "yabai installed", isCore: true))
            case "skhd-binary":
                items.append(checklist(from: item, title: "skhd installed", isCore: true))
            case "yabai-daemon":
                items.append(checklist(from: item, title: "yabai daemon running", isCore: true))
            case "skhd-daemon":
                items.append(checklist(from: item, title: "skhd daemon running", isCore: true))
            case "accessibility":
                items.append(checklist(from: item, title: "Accessibility permission", isCore: false))
            case "yabai-query":
                items.append(checklist(from: item, title: "Live yabai query", isCore: true))
            default:
                continue
            }
        }
        return items.sorted { lhs, rhs in
            if lhs.isCore != rhs.isCore { return lhs.isCore && !rhs.isCore }
            if lhs.status.severityRank != rhs.status.severityRank {
                return lhs.status.severityRank > rhs.status.severityRank
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func checklist(from capability: CapabilityState, title: String, isCore: Bool) -> DoctorChecklistItem {
        DoctorChecklistItem(
            title: title,
            isCore: isCore,
            status: capability.status,
            detail: capability.message,
            remediation: capability.remediationSteps
        )
    }

    private func mappedSystemStatus(from setupState: SetupCheckState?) -> SystemCheckStatus? {
        guard let setupState else { return nil }
        switch setupState {
        case .installed:
            return .good
        case .warning:
            return .warning
        case .missing:
            return .error
        case .unknown:
            return .notice
        }
    }

    private func mappedSystemStatus(from capabilityStatus: CapabilityStatus?) -> SystemCheckStatus? {
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

    private func mergedSystemStatus(_ statuses: [SystemCheckStatus?]) -> SystemCheckStatus {
        statuses.compactMap { $0 }.max(by: { $0.severityRank < $1.severityRank }) ?? .notice
    }

    private func firstDetail(_ candidates: String?..., fallback: String) -> String {
        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { continue }
            return trimmed
        }
        return fallback
    }

}
