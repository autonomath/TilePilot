import Foundation

enum SkhdReloadTargetError: LocalizedError, Equatable {
    case notRunning
    case invalidProcessList
    case multipleInstances

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "skhd is not running. Open System and start shortcuts to activate the saved binding."
        case .invalidProcessList:
            return "Could not identify the running skhd process. Open System and recheck shortcuts."
        case .multipleInstances:
            return "More than one skhd instance is running. Open System and resolve the duplicate shortcut services."
        }
    }
}

enum SkhdReloadTarget {
    /// Only accepts the output of an exact-name, current-user process lookup.
    /// Rejects process groups, PID 1, and ambiguous matches before signaling.
    static func resolve(pgrepOutput: String) -> Result<Int32, SkhdReloadTargetError> {
        let tokens = pgrepOutput.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return .failure(.notRunning) }
        let pids = tokens.compactMap { token -> Int32? in
            guard token.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let pid = Int32(token), pid > 1 else { return nil }
            return pid
        }
        guard pids.count == tokens.count else { return .failure(.invalidProcessList) }
        guard pids.count == 1 else { return .failure(.multipleInstances) }
        return .success(pids[0])
    }
}
