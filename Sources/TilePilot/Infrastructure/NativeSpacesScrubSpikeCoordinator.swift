import AppKit
import ApplicationServices
import Foundation

@MainActor
final class NativeSpacesScrubSpikeCoordinator {
    private enum SessionEndReason: String {
        case completed
        case cancelled
        case appDeactivated
        case error
    }

    private let runner = CommandRunner()
    private var spikeNotificationObservers: [NSObjectProtocol] = []
    private var interactiveNotificationObservers: [NSObjectProtocol] = []
    private var interactiveEventTap: CFMachPort?
    private var interactiveEventTapRunLoopSource: CFRunLoopSource?
    private var dockSwipeRepeatEndTimer: Timer?
    private var dockSwipeRepeatFinalTimer: Timer?
    private var isRunning = false
    private var isInteractiveScrubArmed = false
    private var isInteractiveScrubbing = false
    private var accumulatedHorizontalDelta: CGFloat = 0
    private var lastDockSwipeDelta: Double = 0
    private var dockSwipeOriginOffset: Double = 0
    private var startedDockSwipeGesture = false
    private var interactiveHorizontalScale: Double = 1.0 / 1600.0
    private var scrubTriggerModifiers: NSEvent.ModifierFlags = DesktopScrubModifier.flags(for: DesktopScrubModifier.defaultSelection)
    private var scrubTriggerCharacter: DesktopScrubCharacterKey = .none
    private var isTriggerCharacterHeld = false
    private var scrubSensitivity = 1.0
    private var scrubInvertDirection = true
    private let scrubPerEventDeltaClamp = 0.18
    private let scrubOriginOffsetClamp = 3.0
    private let scrubActivationThreshold = 0.5
    private let scrubCommitThreshold = 0.14
    private let scrubSpaceSeparatorWidth = 63.0

    var interactiveScrubTriggerDescription: String {
        let triggerWords = DesktopScrubModifier.wordsText(for: DesktopScrubModifier.from(flags: scrubTriggerModifiers))
        if scrubTriggerCharacter == .none {
            return "Hold \(triggerWords), move the mouse horizontally, then let go and macOS settles on that desktop."
        }
        return "Hold \(triggerWords) + \(scrubTriggerCharacter.keyDisplayText), move the mouse horizontally, then let go and macOS settles on that desktop."
    }

    var interactiveScrubEnabled: Bool {
        isInteractiveScrubArmed
    }

    func configureInteractiveScrub(
        enabled: Bool,
        triggerModifiers: NSEvent.ModifierFlags,
        triggerCharacter: DesktopScrubCharacterKey,
        sensitivity: Double,
        invertDirection: Bool
    ) -> Bool {
        scrubTriggerModifiers = triggerModifiers.intersection([.shift, .control, .option, .command])
        scrubTriggerCharacter = triggerCharacter
        isTriggerCharacterHeld = false
        scrubSensitivity = min(max(sensitivity, 0.4), 5.0)
        scrubInvertDirection = invertDirection

        guard enabled else {
            disableInteractiveScrubMode()
            return true
        }

        if isInteractiveScrubArmed {
            return true
        }

        return enableInteractiveScrubMode()
    }

    func runFeasibilitySpike() async -> NativeSpacesScrubSpikeRunResult {
        beginExperimentalSession()
        let endReason: SessionEndReason = .completed
        defer {
            teardownExperimentalSession(reason: endReason)
        }

        let machineSummary = [
            ProcessInfo.processInfo.operatingSystemVersionString,
            "arch \(currentArchitecture())",
            "app \(AppModel.currentBundleVersionString())",
        ].joined(separator: " • ")

        var commandResults: [CommandResult] = []
        var attempts: [NativeSpacesScrubProbeAttempt] = []

        let publicAttempt = await probePublicSyntheticHorizontalScrollPath(commandResults: &commandResults)
        attempts.append(publicAttempt)

        let dockSwipeAttempt = await probeUndocumentedDockSwipePath(commandResults: &commandResults)
        attempts.append(dockSwipeAttempt)

        let appKitAttempt = analyzePublicAppKitSwipeTracking()
        attempts.append(appKitAttempt)

        let privateSurfaceAttempt = await inspectPrivateDockSpacesSurface(commandResults: &commandResults)
        attempts.append(privateSurfaceAttempt)

        let anyPublicNativeMotion = attempts.contains {
            $0.apiScope == .publicSupported && $0.producedNativeSpacesMotion && $0.macOSControlledCommitOnRelease
        }
        let anyPrivateNativeMotion = attempts.contains {
            $0.apiScope == .privateUndocumented && $0.producedNativeSpacesMotion && $0.macOSControlledCommitOnRelease
        }

        let recommendation: NativeSpacesScrubRecommendation
        let recommendationSummary: String
        if anyPublicNativeMotion {
            recommendation = .considerProductization
            recommendationSummary = "A supported API path produced real macOS Spaces motion with macOS-controlled commit semantics. This spike can advance toward a productized prototype."
        } else if anyPrivateNativeMotion {
            recommendation = .doNotShipPrivateOnly
            recommendationSummary = "Only a private or undocumented path appears viable. That is not supportable for a shipping feature. Keep the finding as research only unless a supported API appears."
        } else {
            recommendation = .doNotBuild
            recommendationSummary = "Do not build this as a native-feeling Spaces scrub feature on the current approach. The supported probe did not move Spaces at all, and the only promising surface area remains inside Dock/Mission Control private machinery."
        }

        let report = NativeSpacesScrubFeasibilityReport(
            generatedAt: Date(),
            triggerPath: AppModel.experimentalNativeSpacesScrubSpikeDeepLink,
            machineSummary: machineSummary,
            activationPath: [
                "Open `\(AppModel.experimentalNativeSpacesScrubSpikeDeepLink)`.",
                "TilePilot starts an isolated spike session and resets any prior session state.",
                "The coordinator runs a public synthetic horizontal scroll-wheel probe, then inspects Dock private surface evidence."
            ],
            teardownPath: [
                "Stop the isolated spike session on completion, app deactivation, cancellation, or error.",
                "Remove any temporary notification observers.",
                "Restore cursor visibility if a later prototype hides it.",
                "Clear accumulated delta and recentering state so nothing leaks into normal app behavior."
            ],
            attempts: attempts,
            knownLimitations: [
                "Phase 1 does not install a user-facing trigger, shortcut, or overlay. It only runs feasibility probes.",
                "The public probe uses synthetic CGEvent horizontal scroll-wheel events. If macOS requires a deeper gesture path than that, public viability is still effectively absent from a normal app process.",
                "Dock clearly contains Spaces transition internals, but this spike does not call private APIs directly because that would cross from feasibility into unsupported implementation."
            ],
            recommendation: recommendation,
            recommendationSummary: recommendationSummary
        )

        return NativeSpacesScrubSpikeRunResult(report: report, commandResults: commandResults)
    }

    private func beginExperimentalSession() {
        if isRunning {
            teardownExperimentalSession(reason: .cancelled)
        }
        isRunning = true
        accumulatedHorizontalDelta = 0
        lastDockSwipeDelta = 0
        dockSwipeOriginOffset = 0

        let resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.teardownExperimentalSession(reason: .appDeactivated)
            }
        }
        spikeNotificationObservers = [resignObserver]
    }

    private func teardownExperimentalSession(reason: SessionEndReason) {
        guard isRunning || !spikeNotificationObservers.isEmpty else { return }
        for observer in spikeNotificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        spikeNotificationObservers.removeAll()
        accumulatedHorizontalDelta = 0
        lastDockSwipeDelta = 0
        dockSwipeOriginOffset = 0
        isRunning = false
        _ = reason
    }

    @discardableResult
    func enableInteractiveScrubMode() -> Bool {
        if isInteractiveScrubbing {
            endInteractiveScrub(commit: false)
        }
        if isInteractiveScrubArmed {
            removeInteractiveMonitors()
            isInteractiveScrubArmed = false
        }
        let installed = installInteractiveMonitors()
        isInteractiveScrubArmed = installed
        return installed
    }

    func disableInteractiveScrubMode() {
        guard isInteractiveScrubArmed || isInteractiveScrubbing else { return }
        endInteractiveScrub(commit: false)
        removeInteractiveMonitors()
        isInteractiveScrubArmed = false
    }

    @discardableResult
    private func installInteractiveMonitors() -> Bool {
        removeInteractiveMonitors()
        let mask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let coordinator = Unmanaged<NativeSpacesScrubSpikeCoordinator>.fromOpaque(userInfo).takeUnretainedValue()
            MainActor.assumeIsolated {
                coordinator.handleInteractiveCGEvent(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            return false
        }
        interactiveEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        interactiveEventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.endInteractiveScrub(commit: false)
            }
        }
        interactiveNotificationObservers = [resignObserver]
        return true
    }

    private func removeInteractiveMonitors() {
        if let source = interactiveEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        interactiveEventTapRunLoopSource = nil
        interactiveEventTap = nil
        isTriggerCharacterHeld = false
        for observer in interactiveNotificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        interactiveNotificationObservers.removeAll()
        invalidateDockSwipeRepeatTimers()
    }

    private func handleInteractiveCGEvent(type: CGEventType, event: CGEvent) {
        guard isInteractiveScrubArmed else { return }

        switch type {
        case .flagsChanged:
            let triggerActive = scrubTriggerIsActive(NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)))
            if triggerActive, !isInteractiveScrubbing {
                beginInteractiveScrub()
            } else if !triggerActive, isInteractiveScrubbing {
                endInteractiveScrub(commit: true)
            }
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard isInteractiveScrubbing else { return }
            let deltaX = CGFloat(event.getIntegerValueField(.mouseEventDeltaX))
            guard abs(deltaX) > scrubActivationThreshold else { return }
            handleInteractiveMouseDelta(deltaX)
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                guard isInteractiveScrubbing else { return }
                endInteractiveScrub(commit: false)
                return
            }

            if scrubTriggerCharacter != .none, eventMatchesTriggerCharacter(event) {
                isTriggerCharacterHeld = true
                let triggerActive = scrubTriggerIsActive(NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)))
                if triggerActive, !isInteractiveScrubbing {
                    beginInteractiveScrub()
                }
                return
            }

        case .keyUp:
            guard scrubTriggerCharacter != .none, eventMatchesTriggerCharacter(event) else { return }
            isTriggerCharacterHeld = false
            guard isInteractiveScrubbing else { return }
            endInteractiveScrub(commit: true)
        default:
            break
        }
    }

    private func scrubTriggerIsActive(_ flags: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags.intersection([.shift, .control, .option, .command])
        guard relevant == scrubTriggerModifiers else { return false }
        if scrubTriggerCharacter == .none {
            return true
        }
        return isTriggerCharacterHeld
    }

    private func eventMatchesTriggerCharacter(_ event: CGEvent) -> Bool {
        guard scrubTriggerCharacter != .none else { return false }
        let eventKey = DesktopScrubCharacterKey.from(keyCode: event.getIntegerValueField(.keyboardEventKeycode))
        return eventKey == scrubTriggerCharacter
    }

    private func beginInteractiveScrub() {
        guard !isInteractiveScrubbing else { return }
        isInteractiveScrubbing = true
        startedDockSwipeGesture = false
        accumulatedHorizontalDelta = 0
        lastDockSwipeDelta = 0
        dockSwipeOriginOffset = 0
        interactiveHorizontalScale = horizontalScrubScale()
    }

    private func handleInteractiveMouseDelta(_ rawDeltaX: CGFloat) {
        guard abs(rawDeltaX) > scrubActivationThreshold else { return }
        accumulatedHorizontalDelta += rawDeltaX
        let directionMultiplier = scrubInvertDirection ? 1.0 : -1.0
        let scaledDelta = directionMultiplier * Double(rawDeltaX) * interactiveHorizontalScale * scrubSensitivity
        let stepDelta = max(min(scaledDelta, scrubPerEventDeltaClamp), -scrubPerEventDeltaClamp)
        let targetOffset = max(min(dockSwipeOriginOffset + stepDelta, scrubOriginOffsetClamp), -scrubOriginOffsetClamp)
        let appliedDelta = targetOffset - dockSwipeOriginOffset
        guard abs(appliedDelta) > .ulpOfOne else { return }

        if !startedDockSwipeGesture {
            _ = postDockSwipeEvent(delta: appliedDelta, type: 1, phase: 1, invertedFromDevice: false)
            startedDockSwipeGesture = true
        } else {
            _ = postDockSwipeEvent(delta: appliedDelta, type: 1, phase: 2, invertedFromDevice: false)
        }

    }

    private func endInteractiveScrub(commit: Bool) {
        guard isInteractiveScrubbing else { return }

        if isInteractiveScrubbing && startedDockSwipeGesture {
            let shouldCommit = commit && abs(dockSwipeOriginOffset) >= scrubCommitThreshold
            _ = postDockSwipeTermination(committing: shouldCommit)
        }
        isInteractiveScrubbing = false
        startedDockSwipeGesture = false
        accumulatedHorizontalDelta = 0
        lastDockSwipeDelta = 0
        dockSwipeOriginOffset = 0
    }

    private func postDockSwipeTermination(committing: Bool) -> Bool {
        postDockSwipeEvent(
            delta: 0,
            type: 1,
            phase: committing ? 4 : 8,
            invertedFromDevice: false
        )
    }

    private func recordHorizontalDelta(_ deltaX: CGFloat) {
        accumulatedHorizontalDelta += deltaX
    }

    private func horizontalScrubScale() -> Double {
        let screenWidth = max(Double(NSScreen.main?.frame.width ?? 1440), 1)
        let originOffsetForOneSpace = 1.5
        let scale = originOffsetForOneSpace / (screenWidth + scrubSpaceSeparatorWidth)
        if scale.isFinite, scale > 0 {
            return scale
        }
        return 1.0 / 1600.0
    }

    private func probePublicSyntheticHorizontalScrollPath(
        commandResults: inout [CommandResult]
    ) async -> NativeSpacesScrubProbeAttempt {
        let beforeResult = await runner.run(yabaiCommand(["-m", "query", "--spaces", "--space"], timeout: 1.0))
        commandResults.append(beforeResult)
        let beforeSpace = parseSpaceIndex(from: beforeResult.stdout)

        let travel: CGFloat = 960
        recordHorizontalDelta(travel)
        let eventSource = CGEventSource(stateID: .combinedSessionState)
        let scrollEventsPosted = postSyntheticHorizontalScrollGesture(source: eventSource, totalHorizontalTravel: travel)

        try? await Task.sleep(for: .milliseconds(350))

        let afterResult = await runner.run(yabaiCommand(["-m", "query", "--spaces", "--space"], timeout: 1.0))
        commandResults.append(afterResult)
        let afterSpace = parseSpaceIndex(from: afterResult.stdout)

        if let beforeSpace, let afterSpace, beforeSpace != afterSpace {
            let restoreResult = await runner.run(yabaiCommand(["-m", "space", "--focus", String(beforeSpace)], timeout: 1.2))
            commandResults.append(restoreResult)
        }

        var evidence = [
            "Synthetic horizontal travel posted: \(Int(travel)) px",
            "Scroll events posted: \(scrollEventsPosted ? "yes" : "no")",
            "Focused space before probe: \(beforeSpace.map(String.init) ?? "unknown")",
            "Focused space after probe: \(afterSpace.map(String.init) ?? "unknown")",
        ]

        if !beforeResult.isSuccess {
            evidence.append("Initial yabai space query failed: \(beforeResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if !afterResult.isSuccess {
            evidence.append("Final yabai space query failed: \(afterResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let producedNativeMotion = beforeSpace != nil && afterSpace != nil && beforeSpace != afterSpace
        let summary: String
        if producedNativeMotion {
            summary = "Synthetic CGEvent horizontal scroll-wheel injection changed the focused space. This needs manual validation before treating it as true native Spaces scrubbing."
        } else {
            summary = "Synthetic CGEvent horizontal scroll-wheel injection did not move Spaces on this machine. That means the supported event path is not a viable native Spaces scrub mechanism from a normal app process."
        }

        return NativeSpacesScrubProbeAttempt(
            title: "Public CGEvent synthetic horizontal scroll probe",
            apiScope: .publicSupported,
            succeeded: scrollEventsPosted && beforeResult.isSuccess && afterResult.isSuccess,
            producedNativeSpacesMotion: producedNativeMotion,
            macOSControlledCommitOnRelease: false,
            summary: summary,
            evidence: evidence
        )
    }

    private func analyzePublicAppKitSwipeTracking() -> NativeSpacesScrubProbeAttempt {
        NativeSpacesScrubProbeAttempt(
            title: "Public AppKit swipe tracking review",
            apiScope: .publicSupported,
            succeeded: true,
            producedNativeSpacesMotion: false,
            macOSControlledCommitOnRelease: false,
            summary: "AppKit swipe tracking is for handling scroll/swipe events inside an app responder. It does not expose a supported API to drive Mission Control or set native Spaces transition progress globally.",
            evidence: [
                "`NSEvent.trackSwipeEvent(with:...)` is documented for app event handling, not system Spaces control.",
                "No supported AppKit or CoreGraphics API was found for setting Mission Control / Spaces transition progress from a normal app process."
            ]
        )
    }

    private func probeUndocumentedDockSwipePath(
        commandResults: inout [CommandResult]
    ) async -> NativeSpacesScrubProbeAttempt {
        let beforeResult = await runner.run(yabaiCommand(["-m", "query", "--spaces", "--space"], timeout: 1.0))
        commandResults.append(beforeResult)
        let beforeSpace = parseSpaceIndex(from: beforeResult.stdout)

        let deltas: [Double] = [180, 180, 180, 180, 180]
        let postedAny = postHorizontalDockSwipeSequence(deltas: deltas, invertedFromDevice: false)
        try? await Task.sleep(for: .milliseconds(650))

        let afterResult = await runner.run(yabaiCommand(["-m", "query", "--spaces", "--space"], timeout: 1.0))
        commandResults.append(afterResult)
        let afterSpace = parseSpaceIndex(from: afterResult.stdout)

        if let beforeSpace, let afterSpace, beforeSpace != afterSpace {
            let restoreResult = await runner.run(yabaiCommand(["-m", "space", "--focus", String(beforeSpace)], timeout: 1.2))
            commandResults.append(restoreResult)
        }

        let producedNativeMotion = beforeSpace != nil && afterSpace != nil && beforeSpace != afterSpace
        let summary: String
        if producedNativeMotion {
            summary = "An undocumented Dock-swipe gesture event sequence changed the active Space. That is a viable prototype path for real mouse-driven Spaces motion, but it is not a supported API surface."
        } else {
            summary = "The undocumented Dock-swipe gesture sequence did not change Spaces on this machine with the current event recipe. The mechanism remains promising, but this specific prototype did not succeed yet."
        }

        return NativeSpacesScrubProbeAttempt(
            title: "Undocumented Dock-swipe gesture probe",
            apiScope: .privateUndocumented,
            succeeded: postedAny && beforeResult.isSuccess && afterResult.isSuccess,
            producedNativeSpacesMotion: producedNativeMotion,
            macOSControlledCommitOnRelease: producedNativeMotion,
            summary: summary,
            evidence: [
                "Dock-swipe deltas posted: \(deltas.map { String(Int($0)) }.joined(separator: ", "))",
                "Gesture event type: 29 with Dock swipe subtype pair",
                "Focused space before probe: \(beforeSpace.map(String.init) ?? "unknown")",
                "Focused space after probe: \(afterSpace.map(String.init) ?? "unknown")",
                "Recipe adapted from Mac Mouse Fix TouchSimulator dock swipe implementation"
            ]
        )
    }

    private func inspectPrivateDockSpacesSurface(
        commandResults: inout [CommandResult]
    ) async -> NativeSpacesScrubProbeAttempt {
        let command = ShellCommand(
            "/bin/zsh",
            [
                "-lc",
                "/usr/bin/strings -a /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock | /usr/bin/grep -E 'SpaceSwitchTransition|Mission Control switch to previous space|Mission Control switch to next space|currentSpaceID|Changing from mode' | /usr/bin/head -n 12"
            ],
            timeout: 3.0
        )
        let result = await runner.run(command)
        commandResults.append(result)

        let surfaceLines = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let foundPrivateSurface = result.isSuccess && !surfaceLines.isEmpty
        let summary: String
        if foundPrivateSurface {
            summary = "Dock contains explicit Mission Control / Spaces transition strings, which strongly suggests the real native motion lives in private Mission Control machinery rather than a supported app API."
        } else {
            summary = "The Dock private surface probe did not return usable evidence inside the command timeout. That does not create a supported path; it only weakens private-surface evidence on this run."
        }

        var evidence = surfaceLines
        if !result.isSuccess && !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            evidence.append("Dock probe stderr: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        return NativeSpacesScrubProbeAttempt(
            title: "Dock / Mission Control private surface inspection",
            apiScope: .privateUndocumented,
            succeeded: result.isSuccess,
            producedNativeSpacesMotion: false,
            macOSControlledCommitOnRelease: false,
            summary: summary,
            evidence: evidence
        )
    }

    private func postSyntheticHorizontalScrollGesture(source: CGEventSource?, totalHorizontalTravel: CGFloat) -> Bool {
        guard let source else { return false }
        let segments: [(NSEvent.Phase, Int32)] = [
            (.mayBegin, 0),
            (.began, 0),
            (.changed, Int32(totalHorizontalTravel * 0.40)),
            (.changed, Int32(totalHorizontalTravel * 0.35)),
            (.changed, Int32(totalHorizontalTravel * 0.25)),
            (.ended, 0),
        ]

        var postedAny = false
        for (phase, horizontalDelta) in segments {
            guard let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: 0,
                wheel2: horizontalDelta,
                wheel3: 0
            ) else {
                continue
            }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
            event.post(tap: .cghidEventTap)
            postedAny = true
            usleep(18_000)
        }
        return postedAny
    }

    private func postHorizontalDockSwipeSequence(deltas: [Double], invertedFromDevice: Bool) -> Bool {
        guard !deltas.isEmpty else { return false }
        dockSwipeOriginOffset = 0
        lastDockSwipeDelta = 0

        var postedAny = false
        if postDockSwipeEvent(delta: deltas[0], type: 1, phase: 1, invertedFromDevice: invertedFromDevice) {
            postedAny = true
        }
        usleep(16_000)
        for delta in deltas.dropFirst() {
            if postDockSwipeEvent(delta: delta, type: 1, phase: 2, invertedFromDevice: invertedFromDevice) {
                postedAny = true
            }
            usleep(16_000)
        }
        if postDockSwipeEvent(delta: 0, type: 1, phase: 4, invertedFromDevice: invertedFromDevice) {
            postedAny = true
        }
        return postedAny
    }

    @discardableResult
    private func postDockSwipeEvent(delta: Double, type: Double, phase: Int64, invertedFromDevice: Bool) -> Bool {
        let endedPhase: Int64 = 4
        let cancelledPhase: Int64 = 8

        if phase == 1 {
            invalidateDockSwipeRepeatTimers()
            dockSwipeOriginOffset = delta
        } else if phase == 2 {
            if delta == 0 { return false }
            dockSwipeOriginOffset += delta
        }

        var effectivePhase = phase
        if phase == endedPhase {
            let sameSign = (lastDockSwipeDelta == 0 || dockSwipeOriginOffset == 0)
                || ((lastDockSwipeDelta > 0) == (dockSwipeOriginOffset > 0))
            effectivePhase = sameSign ? endedPhase : cancelledPhase
        }

        let posted = postDockSwipePhaseOnly(
            phase: effectivePhase,
            exitSpeed: (effectivePhase == endedPhase || effectivePhase == cancelledPhase) ? lastDockSwipeDelta * 100 : nil,
            type: type,
            invertedFromDevice: invertedFromDevice
        )

        if effectivePhase == endedPhase || effectivePhase == cancelledPhase {
            scheduleDockSwipeRepeatEvents(
                phase: effectivePhase,
                exitSpeed: lastDockSwipeDelta * 100,
                type: type,
                invertedFromDevice: invertedFromDevice
            )
        }

        lastDockSwipeDelta = delta
        return posted
    }

    private func scheduleDockSwipeRepeatEvents(
        phase: Int64,
        exitSpeed: Double,
        type: Double,
        invertedFromDevice: Bool
    ) {
        invalidateDockSwipeRepeatTimers()
        dockSwipeRepeatEndTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = self.postDockSwipePhaseOnly(
                    phase: phase,
                    exitSpeed: exitSpeed,
                    type: type,
                    invertedFromDevice: invertedFromDevice
                )
            }
        }
        dockSwipeRepeatFinalTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = self.postDockSwipePhaseOnly(
                    phase: phase,
                    exitSpeed: exitSpeed,
                    type: type,
                    invertedFromDevice: invertedFromDevice
                )
            }
        }
    }

    private func invalidateDockSwipeRepeatTimers() {
        dockSwipeRepeatEndTimer?.invalidate()
        dockSwipeRepeatFinalTimer?.invalidate()
        dockSwipeRepeatEndTimer = nil
        dockSwipeRepeatFinalTimer = nil
    }

    private func postDockSwipePhaseOnly(
        phase: Int64,
        exitSpeed: Double?,
        type: Double = 1,
        invertedFromDevice: Bool = false
    ) -> Bool {
        guard let e29 = CGEvent(source: nil), let e30 = CGEvent(source: nil) else { return false }

        let subtype: Int64 = 23 // kIOHIDEventTypeDockSwipe
        let eventTypeGesture = 29.0
        let eventTypeMagnify = 30.0
        let magic41 = 33231.0
        let weirdTypeOrSum = 1.401298464324817e-45 // horizontal

        e29.setDoubleValueField(eventField(55), value: eventTypeGesture)
        e29.setDoubleValueField(eventField(41), value: magic41)

        e30.setDoubleValueField(eventField(55), value: eventTypeMagnify)
        e30.setDoubleValueField(eventField(41), value: magic41)
        e30.setDoubleValueField(eventField(110), value: Double(subtype))
        e30.setDoubleValueField(eventField(132), value: Double(phase))
        e30.setDoubleValueField(eventField(134), value: Double(phase))
        e30.setDoubleValueField(eventField(124), value: dockSwipeOriginOffset)

        var originFloat = Float32(dockSwipeOriginOffset)
        let encodedOrigin = withUnsafeBytes(of: &originFloat) { bytes -> UInt32 in
            bytes.load(as: UInt32.self)
        }
        e30.setIntegerValueField(eventField(135), value: Int64(encodedOrigin))

        e30.setDoubleValueField(eventField(119), value: weirdTypeOrSum)
        e30.setDoubleValueField(eventField(139), value: weirdTypeOrSum)
        e30.setDoubleValueField(eventField(123), value: type)
        e30.setDoubleValueField(eventField(165), value: type)
        e30.setIntegerValueField(eventField(136), value: invertedFromDevice ? 1 : 0)

        if let exitSpeed {
            e30.setDoubleValueField(eventField(129), value: exitSpeed)
            e30.setDoubleValueField(eventField(130), value: exitSpeed)
        }

        e30.post(tap: .cgSessionEventTap)
        e29.post(tap: .cgSessionEventTap)
        return true
    }

    private func eventField(_ rawValue: Int) -> CGEventField {
        CGEventField(rawValue: UInt32(rawValue))!
    }

    private func parseSpaceIndex(from raw: String) -> Int? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let index = object["index"] as? Int { return index }
        if let number = object["index"] as? NSNumber { return number.intValue }
        return nil
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
}
