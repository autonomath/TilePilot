import Foundation

enum ManagedHelperLaunchPolicy {
    static func activationArguments(domain: String, label: String, plistPath: String) -> [[String]] {
        [
            ["bootout", "\(domain)/\(label)"],
            ["bootstrap", domain, plistPath],
        ]
    }

    static func requiresPromptLoopRepair(plistData: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
              let dictionary = plist as? [String: Any],
              let keepAlive = dictionary["KeepAlive"] else {
            return false
        }

        if let enabled = keepAlive as? Bool {
            return enabled
        }

        // Conditional KeepAlive dictionaries can also relaunch a permission-blocked
        // helper, so managed agents use one-shot launch semantics instead.
        return true
    }
}
