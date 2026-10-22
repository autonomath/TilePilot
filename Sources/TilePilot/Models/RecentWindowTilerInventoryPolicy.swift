import CoreGraphics
import Foundation

enum RecentWindowTilerInventoryPolicy {
    struct AccessibilityWindow {
        let title: String
        let frame: CGRect?
    }

    static func supportsRole(role: String, subrole: String) -> Bool {
        let role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let subrole = subrole.trimmingCharacters(in: .whitespacesAndNewlines)
        // Missing AX metadata can still describe a controllable window. Known
        // tooltips, sheets and dialogs must not borrow another window's identity.
        return (role.isEmpty || role == "AXWindow") &&
            (subrole.isEmpty || subrole == "AXStandardWindow")
    }

    static func matchingAccessibilityWindowIndex(
        title: String,
        frame: CGRect,
        windows: [AccessibilityWindow]
    ) -> Int? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleMatches = windows.indices.filter {
            !title.isEmpty && windows[$0].title.trimmingCharacters(in: .whitespacesAndNewlines) == title
        }
        if titleMatches.count == 1 { return titleMatches.first }

        let indexes = titleMatches.isEmpty ? Array(windows.indices) : titleMatches
        let frameMatches = indexes.filter { index in
            guard let candidate = windows[index].frame,
                  !frame.isEmpty, !candidate.isEmpty else { return false }
            // A nearest window with unrelated geometry is not an AX match.
            let tolerance: CGFloat = 12
            return abs(candidate.minX - frame.minX) <= tolerance &&
                abs(candidate.minY - frame.minY) <= tolerance &&
                abs(candidate.width - frame.width) <= tolerance &&
                abs(candidate.height - frame.height) <= tolerance
        }
        return frameMatches.count == 1 ? frameMatches.first : nil
    }
}
