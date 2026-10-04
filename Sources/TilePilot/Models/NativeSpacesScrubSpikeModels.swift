import Foundation

enum NativeSpacesScrubAPIScope: String, Codable, Sendable {
    case publicSupported
    case privateUndocumented

    var title: String {
        switch self {
        case .publicSupported:
            return "Public / supported API surface"
        case .privateUndocumented:
            return "Private / undocumented surface"
        }
    }
}

enum NativeSpacesScrubRecommendation: String, Codable, Sendable {
    case considerProductization
    case doNotShipPrivateOnly
    case doNotBuild

    var title: String {
        switch self {
        case .considerProductization:
            return "Consider productization"
        case .doNotShipPrivateOnly:
            return "Private-only prototype; do not ship"
        case .doNotBuild:
            return "Do not build"
        }
    }
}

struct NativeSpacesScrubProbeAttempt: Identifiable, Codable, Sendable {
    let id: UUID
    let title: String
    let apiScope: NativeSpacesScrubAPIScope
    let succeeded: Bool
    let producedNativeSpacesMotion: Bool
    let macOSControlledCommitOnRelease: Bool
    let summary: String
    let evidence: [String]

    init(
        id: UUID = UUID(),
        title: String,
        apiScope: NativeSpacesScrubAPIScope,
        succeeded: Bool,
        producedNativeSpacesMotion: Bool,
        macOSControlledCommitOnRelease: Bool,
        summary: String,
        evidence: [String]
    ) {
        self.id = id
        self.title = title
        self.apiScope = apiScope
        self.succeeded = succeeded
        self.producedNativeSpacesMotion = producedNativeSpacesMotion
        self.macOSControlledCommitOnRelease = macOSControlledCommitOnRelease
        self.summary = summary
        self.evidence = evidence
    }
}

struct NativeSpacesScrubFeasibilityReport: Codable, Sendable {
    let generatedAt: Date
    let triggerPath: String
    let machineSummary: String
    let activationPath: [String]
    let teardownPath: [String]
    let attempts: [NativeSpacesScrubProbeAttempt]
    let knownLimitations: [String]
    let recommendation: NativeSpacesScrubRecommendation
    let recommendationSummary: String
}

struct NativeSpacesScrubSpikeRunResult: Sendable {
    let report: NativeSpacesScrubFeasibilityReport
    let commandResults: [CommandResult]
}

extension NativeSpacesScrubFeasibilityReport {
    func markdown() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]

        var lines: [String] = []
        lines.append("# Native Spaces Scrub Feasibility Report")
        lines.append("")
        lines.append("- Generated: \(formatter.string(from: generatedAt))")
        lines.append("- Trigger: `\(triggerPath)`")
        lines.append("- Machine: \(machineSummary)")
        lines.append("- Recommendation: **\(recommendation.title)**")
        lines.append("")
        lines.append("## Activation Path")
        for step in activationPath {
            lines.append("- \(step)")
        }
        lines.append("")
        lines.append("## Teardown Path")
        for step in teardownPath {
            lines.append("- \(step)")
        }
        lines.append("")
        lines.append("## Attempts")
        for attempt in attempts {
            lines.append("### \(attempt.title)")
            lines.append("- API surface: \(attempt.apiScope.title)")
            lines.append("- Probe succeeded: \(attempt.succeeded ? "Yes" : "No")")
            lines.append("- Produced true native Spaces motion: \(attempt.producedNativeSpacesMotion ? "Yes" : "No")")
            lines.append("- Release/commit stayed macOS-controlled: \(attempt.macOSControlledCommitOnRelease ? "Yes" : "No")")
            lines.append("- Summary: \(attempt.summary)")
            if !attempt.evidence.isEmpty {
                lines.append("- Evidence:")
                for item in attempt.evidence {
                    lines.append("  - \(item)")
                }
            }
            lines.append("")
        }
        lines.append("## Known Limitations")
        for item in knownLimitations {
            lines.append("- \(item)")
        }
        lines.append("")
        lines.append("## Recommendation")
        lines.append(recommendationSummary)
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
