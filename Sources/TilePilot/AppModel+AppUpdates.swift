import AppKit
import Foundation

@MainActor
extension AppModel {
    var currentAppVersion: String {
        Self.currentBundleVersionString()
    }

    var availableAppUpdateRelease: AppUpdateReleaseInfo? {
        appUpdateStatus.availableRelease
    }

    var shouldShowAvailableUpdateBanner: Bool {
        guard let release = availableAppUpdateRelease else { return false }
        return dismissedAppUpdateVersion != release.version
    }

    var appUpdateStatusTitle: String {
        switch appUpdateStatus {
        case .idle:
            return "Not checked yet"
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            return "Up to date"
        case .available(let release):
            return "New version available: \(release.tagName)"
        case .failed:
            return "Update check failed"
        }
    }

    var appUpdateStatusDetail: String {
        switch appUpdateStatus {
        case .idle:
            return "Check GitHub releases to see whether a newer stable TilePilot build is available."
        case .checking:
            return "Checking the latest stable GitHub release for TilePilot."
        case .upToDate(let currentVersion, let checkedAt):
            return "TilePilot \(currentVersion) is current. Last checked \(relativeUpdateTimeString(from: checkedAt))."
        case .available(let release):
            if let publishedAt = release.publishedAt {
                return "\(release.tagName) was published \(relativeUpdateTimeString(from: publishedAt)). Open the GitHub release page to update."
            }
            return "\(release.tagName) is available on GitHub Releases."
        case .failed(let message):
            return message
        }
    }

    var automaticAppUpdateChecksEnabled: Bool {
        if let raw = Bundle.main.object(forInfoDictionaryKey: AppModel.appUpdateAutomaticChecksEnabledInfoKey) as? Bool {
            return raw
        }
        return false
    }

    func checkForAppUpdates(manual: Bool) {
        if manual {
            requestOpenTilePilotTab(.system)
        }
        guard !isCheckingForAppUpdates else {
            if manual {
                lastErrorMessage = "Already checking for updates."
                lastActionMessage = nil
            }
            return
        }

        Task { [weak self] in
            await self?.performAppUpdateCheck(manual: manual)
        }
    }

    func openLatestReleasePage() {
        let targetURL = availableAppUpdateRelease?.releaseURL ?? AppUpdateService.releasesPageURL
        NSWorkspace.shared.open(targetURL)
    }

    func dismissAvailableUpdateBanner() {
        guard let release = availableAppUpdateRelease else { return }
        dismissedAppUpdateVersion = release.version
        UserDefaults.standard.set(release.version, forKey: AppModel.appUpdateDismissedVersionDefaultsKey)
    }

    func shouldRunAutomaticAppUpdateCheck(now: Date = Date()) -> Bool {
        guard automaticAppUpdateChecksEnabled else { return false }
        guard !isCheckingForAppUpdates else { return false }
        guard let lastCheck = appUpdateLastSuccessfulCheckAt else { return true }
        return now.timeIntervalSince(lastCheck) >= 12 * 60 * 60
    }

    private func performAppUpdateCheck(manual: Bool) async {
        isCheckingForAppUpdates = true
        defer { isCheckingForAppUpdates = false }

        let priorStatus = appUpdateStatus
        appUpdateStatus = .checking(manual: manual)

        do {
            let latestRelease = try await appUpdateService.fetchLatestStableRelease()
            let now = Date()
            appUpdateLastSuccessfulCheckAt = now
            UserDefaults.standard.set(now, forKey: AppModel.appUpdateLastSuccessfulCheckAtDefaultsKey)

            guard let currentVersion = AppVersion(currentAppVersion) else {
                clearPersistedKnownAppUpdate()
                appUpdateStatus = .failed(message: "This build does not report a usable app version.")
                if manual {
                    lastErrorMessage = "Update check failed: this build does not report a usable app version."
                    lastActionMessage = nil
                }
                return
            }

            guard let latestRelease,
                  let latestVersion = AppVersion(latestRelease.version),
                  latestVersion > currentVersion else {
                clearPersistedKnownAppUpdate()
                appUpdateStatus = .upToDate(currentVersion: currentAppVersion, checkedAt: now)
                if manual {
                    lastErrorMessage = nil
                }
                return
            }

            persistKnownAppUpdate(latestRelease)
            appUpdateStatus = .available(latestRelease)
            if manual {
                lastErrorMessage = nil
            }
        } catch {
            let message = userFacingAppUpdateErrorMessage(error)
            if case .available = priorStatus {
                appUpdateStatus = priorStatus
            } else if let persisted = loadPersistedKnownAppUpdateIfNewerThanCurrent() {
                appUpdateStatus = .available(persisted)
            } else {
                appUpdateStatus = .failed(message: message)
            }
            if manual {
                lastErrorMessage = "Update check failed: \(message)"
                lastActionMessage = nil
            }
        }
    }

    private func persistKnownAppUpdate(_ release: AppUpdateReleaseInfo) {
        guard let data = try? JSONEncoder().encode(release) else { return }
        UserDefaults.standard.set(data, forKey: AppModel.appUpdateLatestKnownReleaseDefaultsKey)
    }

    private func clearPersistedKnownAppUpdate() {
        UserDefaults.standard.removeObject(forKey: AppModel.appUpdateLatestKnownReleaseDefaultsKey)
    }

    private func loadPersistedKnownAppUpdateIfNewerThanCurrent() -> AppUpdateReleaseInfo? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: AppModel.appUpdateLatestKnownReleaseDefaultsKey),
              let release = try? JSONDecoder().decode(AppUpdateReleaseInfo.self, from: data),
              let current = AppVersion(currentAppVersion),
              let available = AppVersion(release.version),
              available > current else {
            return nil
        }
        return release
    }

    private func userFacingAppUpdateErrorMessage(_ error: Error) -> String {
        if let localized = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String,
           !localized.isEmpty {
            return localized
        }
        return error.localizedDescription
    }

    private func relativeUpdateTimeString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
