import Foundation

enum LiveStateDegradationPolicy {
    static func isMaterialMismatch(yabaiWindowTotal: Int, fallbackWindowTotal: Int) -> Bool {
        guard fallbackWindowTotal >= 3 else { return false }
        return yabaiWindowTotal == 0
    }
}
