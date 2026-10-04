import AppKit
import Foundation

@MainActor
extension AppModel {
    static let experimentalNativeSpacesScrubSpikeDeepLink = "tilepilot://internal/native-spaces-scrub-spike"
    static let experimentalNativeSpacesScrubEnableDeepLink = "tilepilot://internal/enable-native-spaces-scrub"
    static let experimentalNativeSpacesScrubDisableDeepLink = "tilepilot://internal/disable-native-spaces-scrub"

    var experimentalNativeSpacesScrubSpikeEnabled: Bool {
        true
    }

    var desktopScrubTriggerFlags: NSEvent.ModifierFlags {
        DesktopScrubModifier.flags(for: desktopScrubTriggerModifiers)
    }

    var desktopScrubTriggerSymbolsText: String {
        DesktopScrubModifier.symbolsText(for: desktopScrubTriggerModifiers)
    }

    var desktopScrubTriggerWordsText: String {
        let modifierText = DesktopScrubModifier.wordsText(for: desktopScrubTriggerModifiers)
        if desktopScrubTriggerCharacter == .none {
            return modifierText
        }
        return "\(modifierText) + \(desktopScrubTriggerCharacter.keyDisplayText)"
    }

    var desktopScrubTriggerSummaryText: String {
        let modifierSymbols = DesktopScrubModifier.symbolsText(for: desktopScrubTriggerModifiers)
        if desktopScrubTriggerCharacter == .none {
            return modifierSymbols
        }
        return "\(modifierSymbols) + \(desktopScrubTriggerCharacter.keyDisplayText)"
    }

    var desktopScrubSensitivityDisplayText: String {
        String(format: "%.1f", desktopScrubSensitivity)
    }

    func setDesktopScrubInvertDirection(_ enabled: Bool) {
        guard desktopScrubInvertDirection != enabled else { return }
        desktopScrubInvertDirection = enabled
        persistDesktopScrubSettings()
        refreshDesktopScrubConfiguration()
    }

    func setDesktopScrubTriggerCharacter(_ key: DesktopScrubCharacterKey) {
        guard desktopScrubTriggerCharacter != key else { return }
        desktopScrubTriggerCharacter = key
        persistDesktopScrubSettings()
        refreshDesktopScrubConfiguration()
    }

    func setDesktopScrubEnabled(_ enabled: Bool) {
        guard desktopScrubEnabled != enabled else { return }
        desktopScrubEnabled = enabled
        persistDesktopScrubSettings()
        refreshDesktopScrubConfiguration()
    }

    func setDesktopScrubSensitivity(_ value: Double) {
        let clamped = min(max(value, 0.4), 5.0)
        guard abs(desktopScrubSensitivity - clamped) > 0.001 else { return }
        desktopScrubSensitivity = clamped
        persistDesktopScrubSettings()
        refreshDesktopScrubConfiguration()
    }

    func toggleDesktopScrubModifier(_ modifier: DesktopScrubModifier) {
        var updated = desktopScrubTriggerModifiers
        if updated.contains(modifier) {
            guard updated.count > DesktopScrubModifier.minimumSelectionCount else {
                desktopScrubStatusMessage = "Desktop Scrub needs at least two trigger keys."
                desktopScrubStatusIsError = true
                return
            }
            updated.removeAll { $0 == modifier }
        } else {
            updated.append(modifier)
        }

        desktopScrubTriggerModifiers = DesktopScrubModifier.normalize(updated)
        persistDesktopScrubSettings()
        refreshDesktopScrubConfiguration()
    }

    func refreshDesktopScrubConfiguration() {
        let configured = nativeSpacesScrubSpikeCoordinator.configureInteractiveScrub(
            enabled: desktopScrubEnabled,
            triggerModifiers: desktopScrubTriggerFlags,
            triggerCharacter: desktopScrubTriggerCharacter,
            sensitivity: desktopScrubSensitivity,
            invertDirection: desktopScrubInvertDirection
        )

        if desktopScrubEnabled, !configured {
            desktopScrubStatusMessage = "Desktop Scrub could not start. Check Accessibility and Input Monitoring permissions."
            desktopScrubStatusIsError = true
            return
        }

        desktopScrubStatusMessage = nil
        desktopScrubStatusIsError = false
    }

    func persistDesktopScrubSettings() {
        let defaults = UserDefaults.standard
        defaults.set(desktopScrubEnabled, forKey: AppModel.desktopScrubEnabledDefaultsKey)
        defaults.set(desktopScrubTriggerModifiers.map(\.rawValue), forKey: AppModel.desktopScrubTriggerModifiersDefaultsKey)
        defaults.set(desktopScrubTriggerCharacter.rawValue, forKey: AppModel.desktopScrubTriggerCharacterDefaultsKey)
        defaults.set(desktopScrubSensitivity, forKey: AppModel.desktopScrubSensitivityDefaultsKey)
        defaults.removeObject(forKey: "TilePilot.desktopScrubAcceleration")
        defaults.set(desktopScrubInvertDirection, forKey: AppModel.desktopScrubInvertDirectionDefaultsKey)
    }

    func enableExperimentalNativeSpacesScrubInteraction() {
        guard experimentalNativeSpacesScrubSpikeEnabled else {
            lastErrorMessage = "This experimental native Spaces scrub feature is disabled in this build."
            lastActionMessage = nil
            return
        }

        let configured = nativeSpacesScrubSpikeCoordinator.configureInteractiveScrub(
            enabled: true,
            triggerModifiers: DesktopScrubModifier.flags(for: DesktopScrubModifier.defaultSelection),
            triggerCharacter: .none,
            sensitivity: 1.0,
            invertDirection: true
        )
        if configured {
            lastErrorMessage = nil
            lastActionMessage = "Experimental desktop scrub armed. \(nativeSpacesScrubSpikeCoordinator.interactiveScrubTriggerDescription)"
        } else {
            lastErrorMessage = "Experimental desktop scrub could not start."
            lastActionMessage = nil
        }
    }

    func disableExperimentalNativeSpacesScrubInteraction() {
        nativeSpacesScrubSpikeCoordinator.disableInteractiveScrubMode()
        lastErrorMessage = nil
        lastActionMessage = "Experimental desktop scrub disabled."
    }

    func runExperimentalNativeSpacesScrubSpike() async {
        guard experimentalNativeSpacesScrubSpikeEnabled else {
            lastErrorMessage = "This experimental spike is disabled in this build."
            lastActionMessage = nil
            return
        }

        lastErrorMessage = nil
        lastActionMessage = nil

        let result = await nativeSpacesScrubSpikeCoordinator.runFeasibilitySpike()
        nativeSpacesScrubFeasibilityReport = result.report
        for commandResult in result.commandResults.reversed() {
            appendCommandLog(from: commandResult)
        }

        do {
            let urls = try writeNativeSpacesScrubFeasibilityArtifacts(for: result.report)
            nativeSpacesScrubFeasibilityReportURL = urls.markdown
            lastActionMessage = "Native Spaces scrub spike completed. Report saved to \(urls.markdown.lastPathComponent)."
            lastErrorMessage = nil
        } catch {
            nativeSpacesScrubFeasibilityReportURL = nil
            lastErrorMessage = "Native Spaces scrub spike finished, but writing the report failed: \(error.localizedDescription)"
            lastActionMessage = nil
        }
    }

    private func writeNativeSpacesScrubFeasibilityArtifacts(
        for report: NativeSpacesScrubFeasibilityReport
    ) throws -> (markdown: URL, json: URL) {
        let directory = try ensureNativeSpacesScrubDiagnosticsDirectory()
        let stamp = diagnosticsTimestampString(date: report.generatedAt)
        let markdownURL = directory.appendingPathComponent("native-spaces-scrub-feasibility-\(stamp).md")
        let jsonURL = directory.appendingPathComponent("native-spaces-scrub-feasibility-\(stamp).json")

        try report.markdown().write(to: markdownURL, atomically: true, encoding: .utf8)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: jsonURL, options: .atomic)

        return (markdownURL, jsonURL)
    }

    private func ensureNativeSpacesScrubDiagnosticsDirectory() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TilePilot/Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func diagnosticsTimestampString(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}
