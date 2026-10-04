import AppKit
import Foundation

extension Notification.Name {
    static let tilePilotOpenMegamap = Notification.Name("TilePilotOpenMegamap")
    static let tilePilotHideMegamap = Notification.Name("TilePilotHideMegamap")
}

enum MegamapCaptureReason: String, Sendable {
    case manualRefresh
    case beforeTilePilotDesktopSwitch
    case afterTilePilotDesktopSwitch
    case onMegamapPresent
}

@MainActor
extension AppModel {
    func presentMegamap() {
        if isMegamapVisible {
            refreshMegamap()
        } else {
            openMegamapDashboard()
        }
    }

    func openMegamapDashboard() {
        acknowledgeInitialStatusIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        megamapCaptureService.removeAllPersistedCapturesFromDisk()
        megamapScreenRecordingAuthorized = megamapCaptureService.screenRecordingAuthorized()
        Task { [weak self] in
            guard let self else { return }
            await self.refreshLiveState()
            await self.captureCurrentDesktopForMegamapPresentationIfPossible()
            await MainActor.run {
                self.megamapScreenRecordingAuthorized = self.megamapCaptureService.screenRecordingAuthorized()
                self.rebuildMegamapSections()
                NotificationCenter.default.post(name: .tilePilotOpenMegamap, object: nil)
            }
        }
    }

    func refreshMegamap() {
        acknowledgeInitialStatusIfNeeded()
        megamapCaptureService.removeAllPersistedCapturesFromDisk()
        NotificationCenter.default.post(name: .tilePilotHideMegamap, object: nil)
        megamapLastActionMessage = "Refreshing MegaMap…"
        megamapLastErrorMessage = nil
        megamapScreenRecordingAuthorized = megamapCaptureService.screenRecordingAuthorized()
        if !megamapScreenRecordingAuthorized {
            NSApp.activate(ignoringOtherApps: true)
            rebuildMegamapSections()
            NotificationCenter.default.post(name: .tilePilotOpenMegamap, object: nil)
        }
        Task { [weak self] in
            guard let self else { return }
            await self.refreshMegamapCaptureSweep()
        }
    }

    func refreshMegamapDesktop(spaceIndex: Int) {
        acknowledgeInitialStatusIfNeeded()
        megamapCaptureService.removeAllPersistedCapturesFromDisk()
        NotificationCenter.default.post(name: .tilePilotHideMegamap, object: nil)
        megamapLastActionMessage = "Refreshing Desktop \(spaceIndex)…"
        megamapLastErrorMessage = nil
        megamapScreenRecordingAuthorized = megamapCaptureService.screenRecordingAuthorized()
        if !megamapScreenRecordingAuthorized {
            NSApp.activate(ignoringOtherApps: true)
            rebuildMegamapSections()
            NotificationCenter.default.post(name: .tilePilotOpenMegamap, object: nil)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await self.refreshSingleMegamapDesktop(spaceIndex: spaceIndex)
        }
    }

    func requestMegamapScreenRecordingAccess() {
        requestScreenRecordingAccessPrompt()
        megamapScreenRecordingAuthorized = megamapCaptureService.screenRecordingAuthorized()
        if megamapScreenRecordingAuthorized {
            megamapLastActionMessage = "Screen Recording access confirmed."
            megamapLastErrorMessage = nil
        } else {
            megamapLastActionMessage = "Opened Screen Recording settings."
            megamapLastErrorMessage = "If TilePilot is not listed yet, macOS has not registered the capture request. Reopen TilePilot and try Enable Screen Recording again."
        }
        rebuildMegamapSections()
    }

    func setMegamapCacheArmed(_ armed: Bool) {
        guard megamapCacheArmed != armed else { return }
        megamapCacheArmed = armed
        UserDefaults.standard.set(armed, forKey: AppModel.megamapCacheArmedDefaultsKey)
    }

    func scheduleMegamapDestinationCaptureIfNeeded(
        spaceIndex: Int,
        delayMilliseconds: Int = 160,
        minimumAgeSeconds: TimeInterval = 1.0
    ) {
        guard megamapCacheArmed, !isRefreshingMegamap else { return }
        megamapIncrementalDestinationCaptureTask?.cancel()
        megamapIncrementalDestinationCaptureTask = Task { [weak self] in
            guard let self else { return }
            if delayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            }
            guard !Task.isCancelled else { return }
            await self.captureMegamapDesktopIfNeeded(
                spaceIndex: spaceIndex,
                reason: .afterTilePilotDesktopSwitch,
                minimumAgeSeconds: minimumAgeSeconds
            )
        }
    }

    func captureMegamapDesktopIfNeeded(
        spaceIndex: Int,
        reason: MegamapCaptureReason,
        minimumAgeSeconds: TimeInterval = 1.0,
        requireCacheArmed: Bool = true
    ) async {
        guard (!requireCacheArmed || megamapCacheArmed), !isRefreshingMegamap else { return }
        let screenRecordingAuthorized = megamapCaptureService.screenRecordingAuthorized()
        guard screenRecordingAuthorized else {
            megamapScreenRecordingAuthorized = false
            return
        }
        megamapScreenRecordingAuthorized = true

        let snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        guard let snapshot,
              snapshot.source == .yabai,
              let space = snapshot.spaces.first(where: { $0.index == spaceIndex }),
              let display = snapshot.displays.first(where: { $0.id == space.displayId }) else {
            return
        }

        let desktopID = megamapDesktopID(displayID: display.id, desktopIndex: spaceIndex)
        let now = Date()
        if let lastCaptureAt = megamapLastCaptureDateByDesktopID[desktopID],
           now.timeIntervalSince(lastCaptureAt) < minimumAgeSeconds {
            return
        }

        let desktopCountOnDisplay = snapshot.spaces.filter { $0.displayId == display.id }.count
        guard desktopCountOnDisplay > 1 else { return }

        let resolvedDisplaysByID = megamapCaptureService.resolveScreenDescriptors(for: [display])
        guard let resolvedDisplay = resolvedDisplaysByID[display.id] else { return }

        do {
            let record = try megamapCaptureService.capture(display: display, desktopIndex: spaceIndex, screen: resolvedDisplay)
            if let old = megamapCaptureRecordsByDesktopID[desktopID], old.screenshotPath != record.screenshotPath {
                megamapCaptureService.removeCapture(at: old.screenshotPath)
                MegamapScreenshotCache.shared.removeImage(at: old.screenshotPath)
            }
            megamapCaptureRecordsByDesktopID[desktopID] = record
            megamapDesktopMessagesByID[desktopID] = nil
            megamapLastCaptureDateByDesktopID[desktopID] = now
            megamapLastCapturedDesktopID = desktopID
            setMegamapCacheArmed(true)
            if isMegamapVisible {
                rebuildMegamapSections()
            }
        } catch {
            if reason == .manualRefresh {
                megamapDesktopMessagesByID[desktopID] = "This desktop could not be captured just now."
            }
        }
    }

    private func captureCurrentDesktopForMegamapPresentationIfPossible() async {
        guard !isRefreshingMegamap else { return }
        let screenRecordingAuthorized = megamapCaptureService.screenRecordingAuthorized()
        guard screenRecordingAuthorized else {
            megamapScreenRecordingAuthorized = false
            return
        }
        megamapScreenRecordingAuthorized = true

        let snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        let targetSpaceIndex: Int?
        if let snapshot {
            if let activeSpace = activeSpaceIndex(in: snapshot) {
                targetSpaceIndex = activeSpace
            } else {
                targetSpaceIndex = await queryCurrentFocusedSpaceIndex()
            }
        } else {
            targetSpaceIndex = await queryCurrentFocusedSpaceIndex()
        }

        guard let targetSpaceIndex else { return }

        await captureMegamapDesktopIfNeeded(
            spaceIndex: targetSpaceIndex,
            reason: .onMegamapPresent,
            minimumAgeSeconds: 0.0,
            requireCacheArmed: false
        )
    }

    private func refreshSingleMegamapDesktop(spaceIndex: Int) async {
        guard !isRefreshingMegamap else { return }
        isRefreshingMegamap = true
        defer { isRefreshingMegamap = false }

        megamapScreenRecordingAuthorized = megamapCaptureService.screenRecordingAuthorized()
        guard megamapScreenRecordingAuthorized else {
            megamapLastActionMessage = nil
            megamapLastErrorMessage = "Screen Recording is needed for real MegaMap screenshots."
            rebuildMegamapSections()
            NotificationCenter.default.post(name: .tilePilotOpenMegamap, object: nil)
            return
        }

        var snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        if snapshot == nil || snapshot?.source != .yabai || snapshot?.degraded == true {
            await refreshLiveState()
            snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        }

        guard let snapshot,
              snapshot.source == .yabai,
              !snapshot.degraded,
              let space = snapshot.spaces.first(where: { $0.index == spaceIndex }),
              let display = snapshot.displays.first(where: { $0.id == space.displayId }) else {
            megamapLastActionMessage = nil
            megamapLastErrorMessage = "Live desktop data is unavailable right now."
            rebuildMegamapSections()
            NotificationCenter.default.post(name: .tilePilotOpenMegamap, object: nil)
            return
        }

        let displaySpaceCount = snapshot.spaces.filter { $0.displayId == display.id }.count
        guard displaySpaceCount > 1 else {
            megamapLastActionMessage = nil
            megamapLastErrorMessage = "Desktop \(spaceIndex) is on a display with only one desktop."
            rebuildMegamapSections()
            NotificationCenter.default.post(name: .tilePilotOpenMegamap, object: nil)
            return
        }

        let desktopID = megamapDesktopID(displayID: display.id, desktopIndex: spaceIndex)
        let resolvedDisplaysByID = megamapCaptureService.resolveScreenDescriptors(for: [display])

        guard let resolvedDisplay = resolvedDisplaysByID[display.id] else {
            megamapLastActionMessage = nil
            megamapLastErrorMessage = "Could not resolve the macOS display for \(display.name)."
            rebuildMegamapSections()
            NotificationCenter.default.post(name: .tilePilotOpenMegamap, object: nil)
            return
        }

        let switched = await focusDesktopForMegamapCapture(index: spaceIndex)
        guard switched else {
            megamapLastActionMessage = nil
            megamapLastErrorMessage = "Could not switch to Desktop \(spaceIndex) for refresh."
            rebuildMegamapSections()
            NotificationCenter.default.post(name: .tilePilotOpenMegamap, object: nil)
            return
        }

        try? await Task.sleep(for: .milliseconds(240))

        do {
            let payload = try megamapCaptureService.capturedPayload(
                display: display,
                desktopIndex: spaceIndex,
                screen: resolvedDisplay
            )
            let record = try megamapCaptureService.persist(payload)
            if let old = megamapCaptureRecordsByDesktopID[desktopID], old.screenshotPath != record.screenshotPath {
                megamapCaptureService.removeCapture(at: old.screenshotPath)
                MegamapScreenshotCache.shared.removeImage(at: old.screenshotPath)
            }
            megamapCaptureRecordsByDesktopID[desktopID] = record
            megamapDesktopMessagesByID[desktopID] = nil
            megamapLastCaptureDateByDesktopID[desktopID] = record.capturedAt
            megamapLastCapturedDesktopID = desktopID
            setMegamapCacheArmed(true)
            megamapLastActionMessage = "Desktop \(spaceIndex) refreshed."
            megamapLastErrorMessage = nil
        } catch {
            let hasPriorCapture = megamapCaptureRecordsByDesktopID[desktopID] != nil
            megamapLastActionMessage = nil
            megamapLastErrorMessage = hasPriorCapture
                ? "Desktop \(spaceIndex) could not be refreshed. The last screenshot was kept."
                : "Desktop \(spaceIndex) could not be captured just now."
        }

        rebuildMegamapSections()
        NotificationCenter.default.post(name: .tilePilotOpenMegamap, object: nil)
        Task { [weak self] in
            guard let self else { return }
            await self.refreshLiveState()
            await MainActor.run {
                self.rebuildMegamapSections()
            }
        }
    }

    func openMegamapScreenRecordingSettings() {
        requestScreenRecordingAccessPrompt()
        megamapScreenRecordingAuthorized = megamapCaptureService.screenRecordingAuthorized()
        if megamapScreenRecordingAuthorized {
            megamapLastActionMessage = "Screen Recording access confirmed."
            megamapLastErrorMessage = nil
        } else {
            megamapLastActionMessage = "Opened Screen Recording settings."
            megamapLastErrorMessage = "If TilePilot is not listed yet, macOS has not registered the capture request. Reopen TilePilot and try Enable Screen Recording again."
        }
        rebuildMegamapSections()
    }

    private func refreshMegamapCaptureSweep() async {
        guard !isRefreshingMegamap else { return }
        isRefreshingMegamap = true
        megamapCaptureProgress = nil
        defer {
            isRefreshingMegamap = false
            megamapCaptureProgress = nil
        }

        megamapScreenRecordingAuthorized = megamapCaptureService.screenRecordingAuthorized()

        guard megamapScreenRecordingAuthorized else {
            megamapLastErrorMessage = "Screen Recording is needed for real megamap screenshots. TilePilot is showing synthetic fallback previews for now."
            megamapLastActionMessage = nil
            return
        }

        var snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        if snapshot == nil || snapshot?.source != .yabai || snapshot?.degraded == true {
            await refreshLiveState()
            snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        }

        guard let snapshot,
              snapshot.source == .yabai,
              !snapshot.degraded else {
            megamapLastErrorMessage = "Live desktop data is unavailable right now, so MegaMap could not start a fresh sweep."
            megamapLastActionMessage = nil
            rebuildMegamapSections()
            NotificationCenter.default.post(name: .tilePilotOpenMegamap, object: nil)
            return
        }

        let targets = await queryMegamapCaptureTargets(using: snapshot)

        guard !targets.isEmpty else {
            megamapLastErrorMessage = "No multi-desktop displays are available to capture."
            megamapLastActionMessage = nil
            rebuildMegamapSections()
            NotificationCenter.default.post(name: .tilePilotOpenMegamap, object: nil)
            return
        }

        let resolvedDisplaysByID = megamapCaptureService.resolveScreenDescriptors(
            for: Array(Dictionary(grouping: targets, by: { $0.display.id }).compactMap { $0.value.first?.display })
        )
        let originalSpace = await queryCurrentFocusedSpaceIndex() ?? activeSpaceIndex(in: snapshot)
        var successCount = 0
        var failureCount = 0
        var updatedCaptureRecordsByDesktopID = megamapCaptureRecordsByDesktopID
        var updatedDesktopMessagesByID = megamapDesktopMessagesByID
        var replacedCapturePaths: [String] = []
        var pendingPayloads: [(desktopID: String, payload: MegamapCaptureService.CapturedImagePayload)] = []
        var switchVerificationDurations: [Double] = []
        var captureDurations: [Double] = []
        var switchFailureDesktopIndexes: [Int] = []
        var captureFailureDesktopIndexes: [Int] = []
        var saveFailureDesktopIndexes: [Int] = []
        let refreshStart = Date()
        var firstSwitchStartedAt: Date?

        NotificationCenter.default.post(name: .tilePilotHideMegamap, object: nil)

        for target in targets {
            let desktopID = megamapDesktopID(displayID: target.display.id, desktopIndex: target.desktopIndex)
            if firstSwitchStartedAt == nil {
                firstSwitchStartedAt = Date()
            }
            let switchStart = Date()
            let switched = await focusDesktopForMegamapCapture(index: target.desktopIndex)
            switchVerificationDurations.append(Date().timeIntervalSince(switchStart) * 1000)
            guard switched else {
                failureCount += 1
                switchFailureDesktopIndexes.append(target.desktopIndex)
                updatedDesktopMessagesByID[desktopID] = "Could not switch to Desktop \(target.desktopIndex) during sweep. Using any last capture available."
                continue
            }

            try? await Task.sleep(for: .milliseconds(240))

            do {
                guard let resolvedDisplay = resolvedDisplaysByID[target.display.id] else {
                    throw NSError(
                        domain: "MegamapCaptureService",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Could not resolve the macOS display for \(target.display.name)."]
                    )
                }
                let captureStart = Date()
                let payload = try megamapCaptureService.capturedPayload(
                    display: target.display,
                    desktopIndex: target.desktopIndex,
                    screen: resolvedDisplay
                )
                captureDurations.append(Date().timeIntervalSince(captureStart) * 1000)
                pendingPayloads.append((desktopID: desktopID, payload: payload))
                successCount += 1
            } catch {
                failureCount += 1
                captureFailureDesktopIndexes.append(target.desktopIndex)
                let hasPriorCapture = updatedCaptureRecordsByDesktopID[desktopID] != nil
                updatedDesktopMessagesByID[desktopID] = hasPriorCapture
                    ? "Using the last capture because this desktop could not be captured just now."
                    : "This desktop could not be captured just now."
            }
        }

        if let originalSpace {
            _ = await focusDesktopForMegamapCapture(index: originalSpace)
            try? await Task.sleep(for: .milliseconds(30))
        }

        for item in pendingPayloads {
            do {
                let record = try megamapCaptureService.persist(item.payload)
                if let old = updatedCaptureRecordsByDesktopID[item.desktopID], old.screenshotPath != record.screenshotPath {
                    replacedCapturePaths.append(old.screenshotPath)
                    MegamapScreenshotCache.shared.removeImage(at: old.screenshotPath)
                }
                updatedCaptureRecordsByDesktopID[item.desktopID] = record
                updatedDesktopMessagesByID[item.desktopID] = nil
            } catch {
                failureCount += 1
                successCount = max(0, successCount - 1)
                if let desktopIndex = item.payload.desktopIndex as Int? {
                    saveFailureDesktopIndexes.append(desktopIndex)
                }
                let hasPriorCapture = updatedCaptureRecordsByDesktopID[item.desktopID] != nil
                updatedDesktopMessagesByID[item.desktopID] = hasPriorCapture
                    ? "Using the last capture because this desktop could not be saved just now."
                    : "This desktop could not be saved just now."
            }
        }

        megamapCaptureRecordsByDesktopID = updatedCaptureRecordsByDesktopID
        megamapDesktopMessagesByID = updatedDesktopMessagesByID
        for (desktopID, record) in updatedCaptureRecordsByDesktopID {
            megamapLastCaptureDateByDesktopID[desktopID] = record.capturedAt
            megamapLastCapturedDesktopID = desktopID
        }
        replacedCapturePaths.forEach {
            megamapCaptureService.removeCapture(at: $0)
            MegamapScreenshotCache.shared.removeImage(at: $0)
        }
        rebuildMegamapSections()
        NotificationCenter.default.post(name: .tilePilotOpenMegamap, object: nil)
        Task { [weak self] in
            guard let self else { return }
            await self.refreshLiveState()
            await MainActor.run {
                self.rebuildMegamapSections()
            }
        }

        megamapLastRefreshedAt = Date()
        if successCount > 0 {
            setMegamapCacheArmed(true)
        }
        let totalSweepMilliseconds = Date().timeIntervalSince(refreshStart) * 1000
        let firstSwitchLatencyMilliseconds = firstSwitchStartedAt.map { $0.timeIntervalSince(refreshStart) * 1000 } ?? 0
        recordMegamapRefreshDiagnostics(
            firstSwitchLatencyMilliseconds: firstSwitchLatencyMilliseconds,
            averageSwitchVerificationMilliseconds: averageMilliseconds(switchVerificationDurations),
            averageCaptureMilliseconds: averageMilliseconds(captureDurations),
            totalSweepMilliseconds: totalSweepMilliseconds,
            capturedDesktopCount: successCount,
            failedDesktopCount: failureCount
        )
        if successCount > 0 && failureCount == 0 {
            megamapLastActionMessage = "MegaMap refreshed for \(successCount) desktop\(successCount == 1 ? "" : "s")."
            megamapLastErrorMessage = nil
        } else if successCount > 0 {
            megamapLastActionMessage = "MegaMap refreshed for \(successCount) desktop\(successCount == 1 ? "" : "s")."
            megamapLastErrorMessage = megamapSweepFailureSummary(
                switchFailures: switchFailureDesktopIndexes,
                captureFailures: captureFailureDesktopIndexes,
                saveFailures: saveFailureDesktopIndexes
            )
        } else {
            megamapLastActionMessage = nil
            megamapLastErrorMessage = megamapSweepFailureSummary(
                switchFailures: switchFailureDesktopIndexes,
                captureFailures: captureFailureDesktopIndexes,
                saveFailures: saveFailureDesktopIndexes,
                allFailed: true
            )
        }
    }

    private func megamapSweepFailureSummary(
        switchFailures: [Int],
        captureFailures: [Int],
        saveFailures: [Int],
        allFailed: Bool = false
    ) -> String {
        var parts: [String] = []
        if !switchFailures.isEmpty {
            parts.append("Could not switch to Desktop \(desktopListSummary(switchFailures)).")
        }
        if !captureFailures.isEmpty {
            parts.append("Could not capture Desktop \(desktopListSummary(captureFailures)).")
        }
        if !saveFailures.isEmpty {
            parts.append("Could not save Desktop \(desktopListSummary(saveFailures)).")
        }

        if parts.isEmpty {
            return allFailed
                ? "MegaMap could not refresh any desktops in this sweep."
                : "Some desktops could not be refreshed. Last screenshots were kept where available."
        }

        let suffix = allFailed
            ? " MegaMap kept any last screenshots that were already available."
            : " Last screenshots were kept where available."
        return parts.joined(separator: " ") + suffix
    }

    private func desktopListSummary(_ indexes: [Int]) -> String {
        let unique = Array(Set(indexes)).sorted()
        if unique.count == 1 {
            return "#\(unique[0])"
        }
        return unique.map { "#\($0)" }.joined(separator: ", ")
    }

    private func averageMilliseconds(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    func rebuildMegamapSections() {
        let snapshot = latestLiveStateSnapshot ?? liveStateSnapshot
        let previewDisplays: [OverviewDisplayPreview]
        if let snapshot, snapshot.source == .yabai, !snapshot.degraded {
            previewDisplays = buildOverviewPreviews(from: snapshot)
        } else {
            previewDisplays = []
        }

        let previewDisplayByID = Dictionary(uniqueKeysWithValues: previewDisplays.map { ($0.id, $0) })
        let previewDesktopByID = Dictionary(
            previewDisplays
                .flatMap { display in
                    display.desktops.map { (megamapDesktopID(displayID: display.id, desktopIndex: $0.desktopIndex), $0) }
                },
            uniquingKeysWith: { first, _ in first }
        )
        let capturedByDisplay = Dictionary(grouping: megamapCaptureRecordsByDesktopID.values, by: \.displayID)

        let orderedDisplayIDs = Array(Set(previewDisplays.map(\.id) + capturedByDisplay.keys))
            .sorted { lhs, rhs in
                let lhsFocused = previewDisplayByID[lhs]?.focused ?? false
                let rhsFocused = previewDisplayByID[rhs]?.focused ?? false
                if lhsFocused != rhsFocused { return lhsFocused && !rhsFocused }
                return lhs < rhs
            }

        megamapDisplaySections = orderedDisplayIDs.compactMap { displayID in
            let previewDisplay = previewDisplayByID[displayID]
            let displayState = snapshot?.displays.first(where: { $0.id == displayID })
            let captures = capturedByDisplay[displayID] ?? []
            let desktopIndexes = Array(
                Set((previewDisplay?.desktops.map(\.desktopIndex) ?? []) + captures.map(\.desktopIndex))
            ).sorted()
            guard !desktopIndexes.isEmpty else { return nil }

            let name = previewDisplay?.name ?? captures.first?.displayName ?? "Display \(displayID)"
            let focused = previewDisplay?.focused ?? false
            let desktops = desktopIndexes.map { desktopIndex -> MegamapDesktopSection in
                let desktopID = megamapDesktopID(displayID: displayID, desktopIndex: desktopIndex)
                let preview = previewDesktopByID[desktopID]
                let capture = megamapCaptureRecordsByDesktopID[desktopID]
                let screenshotPath = capture.flatMap {
                    megamapCaptureService.captureExists(at: $0.screenshotPath) ? $0.screenshotPath : nil
                }
                let contentMode: MegamapDesktopContentMode
                if screenshotPath != nil {
                    contentMode = .screenshot
                } else if preview != nil {
                    contentMode = .syntheticFallback
                } else {
                    contentMode = .unavailable
                }

                let message = megamapDesktopMessagesByID[desktopID]
                    ?? (contentMode == .syntheticFallback && !megamapScreenRecordingAuthorized
                        ? "Screen Recording is needed for real screenshots. Showing the synthetic fallback for now."
                        : nil)

                return MegamapDesktopSection(
                    id: desktopID,
                    displayID: displayID,
                    displayName: name,
                    displayAspectRatio: capture?.displayAspectRatio ?? previewDisplay?.aspectRatio ?? 1.6,
                    displayFrameX: displayState?.frameX ?? capture?.capturedFrameX ?? 0,
                    displayFrameY: displayState?.frameY ?? capture?.capturedFrameY ?? 0,
                    displayFrameW: displayState?.frameW ?? capture?.capturedFrameW ?? 1,
                    displayFrameH: displayState?.frameH ?? capture?.capturedFrameH ?? 1,
                    desktopIndex: desktopIndex,
                    focused: preview?.focused ?? false,
                    visible: preview?.visible ?? false,
                    tilingEnabled: preview?.tilingEnabled,
                    contentMode: contentMode,
                    screenshotPath: screenshotPath,
                    screenshotCropX: capture?.capturedFrameX ?? displayState?.frameX ?? 0,
                    screenshotCropY: capture?.capturedFrameY ?? displayState?.frameY ?? 0,
                    screenshotCropW: capture?.capturedFrameW ?? displayState?.frameW ?? 1,
                    screenshotCropH: capture?.capturedFrameH ?? displayState?.frameH ?? 1,
                    capturedAt: capture?.capturedAt,
                    fallbackPreview: preview,
                    message: message
                )
            }

            guard desktops.count > 1 else { return nil }

            return MegamapDisplaySection(
                id: displayID,
                name: name,
                focused: focused,
                desktops: desktops
            )
        }
    }

    private func megamapDesktopID(displayID: Int, desktopIndex: Int) -> String {
        "megamap-\(displayID)-\(desktopIndex)"
    }

    private func queryMegamapCaptureTargets(using snapshot: LiveStateSnapshot) async -> [(display: DisplayState, desktopIndex: Int)] {
        let query = await doctorService.runSupportCommand(
            yabaiCommand(["-m", "query", "--spaces"], timeout: 1.5)
        )
        appendCommandLog(from: query)

        func parseInt(_ value: Any?) -> Int? {
            if let int = value as? Int { return int }
            if let number = value as? NSNumber { return number.intValue }
            if let string = value as? String { return Int(string) }
            return nil
        }
        let orderedDisplays = snapshot.displays.sorted { lhs, rhs in
            if lhs.focused != rhs.focused { return lhs.focused && !rhs.focused }
            return lhs.id < rhs.id
        }

        guard query.isSuccess,
              let data = query.stdout.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return orderedDisplays.flatMap { display -> [(display: DisplayState, desktopIndex: Int)] in
                let spaces = snapshot.spaces
                    .filter { $0.displayId == display.id }
                    .sorted { $0.index < $1.index }
                guard spaces.count > 1 else { return [] }
                return spaces.map { (display: display, desktopIndex: $0.index) }
            }
        }

        let spacesByDisplayID = Dictionary(grouping: rows.compactMap { row -> (displayID: Int, index: Int)? in
            guard let displayID = parseInt(row["display"]),
                  let index = parseInt(row["index"]) else {
                return nil
            }
            return (displayID, index)
        }, by: \.displayID)

        return orderedDisplays.flatMap { display -> [(display: DisplayState, desktopIndex: Int)] in
            let spaces = (spacesByDisplayID[display.id] ?? [])
                .map(\.index)
                .sorted()
            guard spaces.count > 1 else { return [] }
            return spaces.map { (display: display, desktopIndex: $0) }
        }
    }

    private var isMegamapVisible: Bool {
        NSApp.windows.contains { window in
            window.title == "MegaMap" && window.isVisible
        }
    }
}
