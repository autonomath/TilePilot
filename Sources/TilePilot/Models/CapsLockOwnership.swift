import Foundation

/// Another tool that already turned Caps Lock into something else. TilePilot never takes Caps
/// Lock away from it.
enum CapsLockOwner: Equatable, Sendable {
    case raycastHyperKey
    case karabiner
    case otherRemap

    var explanation: String {
        switch self {
        case .raycastHyperKey:
            return "Raycast's Hyper Key uses Caps Lock. To use Caps Lock here, turn it off in Raycast Settings → Keyboard → Hyper Key."
        case .karabiner:
            return "Karabiner-Elements is running and handles the keyboard. Quit it to use Caps Lock here."
        case .otherRemap:
            return "Another app already remaps Caps Lock. Remove that remap to use Caps Lock here."
        }
    }
}

/// Reads and edits the keyboard's UserKeyMapping (the setting `hidutil` changes), keeping
/// every entry that isn't TilePilot's.
enum CapsLockOwnership {
    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"
    /// Keyboard usage page 7, usage 0x39.
    static let capsLockUsage: UInt64 = 0x7_0000_0039
    /// F18 (usage 0x6D), which macOS reports as key code 79.
    static let tilePilotTargetUsage: UInt64 = 0x7_0000_006D
    /// F20 (usage 0x6F): Raycast's Hyper Key maps Caps Lock here while it's on.
    static let raycastTargetUsage: UInt64 = 0x7_0000_006F

    /// Decides who owns Caps Lock from the live keyboard mappings. A Caps Lock → F18 entry
    /// counts as TilePilot's only while TilePilot remembers adding it.
    static func owner(
        keyboardMappings: [[[String: Any]]],
        tilePilotApplied: Bool,
        raycastRunning: Bool,
        karabinerRunning: Bool
    ) -> CapsLockOwner? {
        if karabinerRunning { return .karabiner }
        for entries in keyboardMappings {
            for entry in entries where usage(entry[sourceKey]) == capsLockUsage {
                let destination = usage(entry[destinationKey])
                if tilePilotApplied, destination == tilePilotTargetUsage { continue }
                return raycastRunning && destination == raycastTargetUsage ? .raycastHyperKey : .otherRemap
            }
        }
        return nil
    }

    /// Karabiner's remapping engine: karabiner_grabber in older versions, Karabiner-Core-Service
    /// in newer ones. Process names may be cut to 16 characters.
    static func isKarabinerEngine(processName: String) -> Bool {
        let name = processName.lowercased()
        return name.hasPrefix("karabiner_grabb") || name.hasPrefix("karabiner-core")
    }

    /// One keyboard's mapping with TilePilot's entry added, or nil when Caps Lock is already
    /// mapped there (by TilePilot or anyone else).
    static func addingTilePilotEntry(to entries: [[String: Any]]) -> [[String: Any]]? {
        guard !entries.contains(where: { usage($0[sourceKey]) == capsLockUsage }) else { return nil }
        return entries + [[
            sourceKey: NSNumber(value: capsLockUsage),
            destinationKey: NSNumber(value: tilePilotTargetUsage),
        ]]
    }

    /// One keyboard's mapping without TilePilot's entry, or nil when it has none.
    static func removingTilePilotEntry(from entries: [[String: Any]]) -> [[String: Any]]? {
        let kept = entries.filter { !isTilePilotEntry($0) }
        return kept.count == entries.count ? nil : kept
    }

    static func hasTilePilotEntry(_ entries: [[String: Any]]) -> Bool {
        entries.contains(where: isTilePilotEntry)
    }

    private static func isTilePilotEntry(_ entry: [String: Any]) -> Bool {
        usage(entry[sourceKey]) == capsLockUsage && usage(entry[destinationKey]) == tilePilotTargetUsage
    }

    private static func usage(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
    }
}
