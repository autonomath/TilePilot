import AppKit
import Foundation

@MainActor
final class AppIconResolver {
    static let shared = AppIconResolver()

    private let fileManager = FileManager.default
    private var urlCache: [String: URL] = [:]
    private var missingURLCache: Set<String> = []
    private var baseIconCache: [String: NSImage] = [:]
    private var missingIconCache: Set<String> = []
    private var sizedIconCache: [String: NSImage] = [:]
    private var runningIconCache: [String: NSImage] = [:]
    private var runningIconCacheUpdatedAt = Date.distantPast
    private let runningIconCacheTTL: TimeInterval = 30.0

    private var searchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        ]
    }

    func icon(forAppNamed appName: String, size: CGFloat? = nil) -> NSImage? {
        let key = normalizedAppName(appName)
        guard !key.isEmpty else { return nil }

        if let cached = baseIconCache[key] {
            return sizedIcon(from: cached, key: key, size: size)
        }
        if let runningIcon = runningIcon(forNormalizedAppName: key) {
            baseIconCache[key] = runningIcon
            missingIconCache.remove(key)
            return sizedIcon(from: runningIcon, key: key, size: size)
        }
        if missingIconCache.contains(key) {
            return nil
        }

        guard let resolved = resolveIcon(forNormalizedAppName: key) else {
            missingIconCache.insert(key)
            return nil
        }

        baseIconCache[key] = resolved
        return sizedIcon(from: resolved, key: key, size: size)
    }

    private func sizedIcon(from baseIcon: NSImage, key: String, size: CGFloat?) -> NSImage? {
        guard let size else { return baseIcon }
        let sizeKey = "\(key)|\(Int(size.rounded()))"
        if let cached = sizedIconCache[sizeKey] {
            return cached
        }

        let resized = (baseIcon.copy() as? NSImage) ?? baseIcon
        resized.size = NSSize(width: size, height: size)
        sizedIconCache[sizeKey] = resized
        return resized
    }

    private func resolveIcon(forNormalizedAppName appName: String) -> NSImage? {
        guard let appURL = resolveAppURL(forNormalizedAppName: appName) else { return nil }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    private func runningIcon(forNormalizedAppName appName: String) -> NSImage? {
        refreshRunningIconCacheIfNeeded()
        return runningIconCache[appName]
    }

    private func refreshRunningIconCacheIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(runningIconCacheUpdatedAt) > runningIconCacheTTL else { return }

        var nextCache: [String: NSImage] = [:]
        for runningApp in NSWorkspace.shared.runningApplications {
            let key = normalizedAppName(runningApp.localizedName ?? "")
            guard !key.isEmpty, let icon = runningApp.icon else { continue }
            nextCache[key] = icon
        }
        runningIconCache = nextCache
        runningIconCacheUpdatedAt = now
    }

    private func resolveAppURL(forNormalizedAppName appName: String) -> URL? {
        if let cached = urlCache[appName] {
            return cached
        }
        if missingURLCache.contains(appName) {
            return nil
        }

        let exactName = "\(appName).app"

        for directory in searchDirectories {
            let directURL = directory.appendingPathComponent(exactName, isDirectory: true)
            if fileManager.fileExists(atPath: directURL.path) {
                urlCache[appName] = directURL
                missingURLCache.remove(appName)
                return directURL
            }
        }

        for directory in searchDirectories where fileManager.fileExists(atPath: directory.path) {
            let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: options
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                let candidateName = normalizedAppName(url.deletingPathExtension().lastPathComponent)
                if candidateName == appName {
                    urlCache[appName] = url
                    missingURLCache.remove(appName)
                    return url
                }
            }
        }

        missingURLCache.insert(appName)
        return nil
    }

    private func normalizedAppName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
