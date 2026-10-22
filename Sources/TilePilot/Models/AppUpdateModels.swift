import Foundation

enum AppUpdateCheckPolicy {
    static let successfulCheckInterval: TimeInterval = 12 * 60 * 60
    static let failedCheckRetryInterval: TimeInterval = 30 * 60

    static func shouldRun(
        enabled: Bool,
        isChecking: Bool,
        lastSuccessfulCheckAt: Date?,
        now: Date
    ) -> Bool {
        guard enabled, !isChecking else { return false }
        guard let lastSuccessfulCheckAt else { return true }
        return now.timeIntervalSince(lastSuccessfulCheckAt) >= successfulCheckInterval
    }

    static func nextDelay(
        lastSuccessfulCheckAt: Date?,
        latestAttemptResult: Bool?,
        now: Date
    ) -> TimeInterval {
        if latestAttemptResult == false {
            return failedCheckRetryInterval
        }
        guard let lastSuccessfulCheckAt else {
            return latestAttemptResult == nil ? failedCheckRetryInterval : 1
        }
        let remaining = successfulCheckInterval - now.timeIntervalSince(lastSuccessfulCheckAt)
        return min(successfulCheckInterval, max(1, remaining))
    }
}

struct AppVersion: Comparable, Hashable, Sendable {
    let normalized: String
    private let components: [Int]

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withoutPrefix: String
        if trimmed.lowercased().hasPrefix("v") {
            withoutPrefix = String(trimmed.dropFirst())
        } else {
            withoutPrefix = trimmed
        }

        let numericPrefix = withoutPrefix.prefix { $0.isNumber || $0 == "." }
        guard !numericPrefix.isEmpty else { return nil }

        let pieces = numericPrefix.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }

        let parsedComponents = pieces.compactMap { Int($0) }
        guard parsedComponents.count == pieces.count, !parsedComponents.isEmpty else { return nil }

        self.components = parsedComponents
        self.normalized = parsedComponents.map(String.init).joined(separator: ".")
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let lhsValue = index < lhs.components.count ? lhs.components[index] : 0
            let rhsValue = index < rhs.components.count ? rhs.components[index] : 0
            if lhsValue != rhsValue {
                return lhsValue < rhsValue
            }
        }
        return false
    }

    /// Missing trailing components count as zero, matching `<`: 0.2.12 equals 0.2.12.0.
    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    func hash(into hasher: inout Hasher) {
        var significant = components
        while significant.count > 1, significant.last == 0 {
            significant.removeLast()
        }
        hasher.combine(significant)
    }
}

func normalizedAppVersionString(from rawValue: String) -> String? {
    AppVersion(rawValue)?.normalized
}

struct AppUpdateReleaseInfo: Codable, Equatable, Sendable {
    let tagName: String
    let version: String
    let releaseName: String?
    let releaseURL: URL
    let publishedAt: Date?
    let body: String?
}

enum AppUpdateStatus: Equatable, Sendable {
    case idle
    case checking(manual: Bool)
    case upToDate(currentVersion: String, checkedAt: Date)
    case available(AppUpdateReleaseInfo)
    case failed(message: String)

    var availableRelease: AppUpdateReleaseInfo? {
        if case .available(let release) = self {
            return release
        }
        return nil
    }

    var isChecking: Bool {
        if case .checking = self {
            return true
        }
        return false
    }
}
