import Foundation

func trimForUI(_ string: String, maxLength: Int = 220) -> String {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > maxLength else { return trimmed }
    return String(trimmed.prefix(maxLength)) + "..."
}
