import Foundation

enum ManagedHelperKind: String, Codable, CaseIterable, Sendable {
    case yabai
    case skhd

    var executableName: String { rawValue }

    var launchAgentLabel: String {
        "com.klode.tilepilot.\(rawValue)"
    }

    var displayName: String {
        rawValue
    }
}

struct BundledHelperDefinition: Codable, Sendable {
    let helper: ManagedHelperKind
    let version: String
    let architecture: String
    let sourceURL: String
    let sourceRevision: String
    let checksumSHA256: String
}

struct BundledHelperManifest: Codable, Sendable {
    let generatedAt: Date
    let helpers: [BundledHelperDefinition]
}

struct ManagedInstalledHelper: Codable, Sendable {
    let helper: ManagedHelperKind
    let version: String
    let architecture: String
    let installedPath: String
    let sourceChecksumSHA256: String
}

struct ManagedHelperInstallState: Codable, Sendable {
    let updatedAt: Date
    let helpers: [ManagedInstalledHelper]
    let launchAgentsInstalled: Bool
    let servicesBootstrapped: Bool
}
