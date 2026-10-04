import Foundation

struct ConfigBackupInfo: Identifiable, Codable, Sendable {
    let id: UUID
    let path: String
    let createdAt: Date
    let sizeBytes: Int64
}

struct EditorTarget: Equatable, Sendable {
    let path: String
    let line: Int?
}

enum EditableFileKind: String, Codable, CaseIterable, Sendable {
    case yabairc
    case skhdrc
    case script
    case other

    var displayName: String {
        switch self {
        case .yabairc: return "yabairc"
        case .skhdrc: return "skhdrc"
        case .script: return "script"
        case .other: return "file"
        }
    }
}

struct EditableConfigFile: Identifiable, Codable, Sendable, Hashable {
    let path: String
    let displayName: String
    let kind: EditableFileKind
    let exists: Bool
    let isDiscovered: Bool

    var id: String { path }
}

struct EditableFileDocumentState: Sendable {
    let file: EditableConfigFile
    let content: String
    let backups: [ConfigBackupInfo]
}

struct EditableFileSaveResult: Sendable {
    let file: EditableConfigFile
    let backups: [ConfigBackupInfo]
    let previousBackup: ConfigBackupInfo?
}

struct EditableFileRestoreResult: Sendable {
    let file: EditableConfigFile
    let backups: [ConfigBackupInfo]
    let restoredBackup: ConfigBackupInfo
    let preRestoreBackup: ConfigBackupInfo?
}
