import Foundation

enum MegamapEmptyState: Equatable {
    case loading
    case desktopDataUnavailable
    case needsMultipleDesktops
    case noDesktops

    init(snapshot: LiveStateSnapshot?) {
        guard let snapshot else {
            self = .loading
            return
        }
        guard snapshot.source == .yabai, !snapshot.degraded else {
            self = .desktopDataUnavailable
            return
        }
        guard !snapshot.displays.isEmpty, !snapshot.spaces.isEmpty else {
            self = .noDesktops
            return
        }
        let desktopCounts = Dictionary(grouping: snapshot.spaces, by: \.displayId)
        self = snapshot.displays.contains { (desktopCounts[$0.id]?.count ?? 0) > 1 }
            ? .noDesktops
            : .needsMultipleDesktops
    }

    var title: String {
        switch self {
        case .loading: "Loading desktops…"
        case .desktopDataUnavailable: "Desktop data is unavailable"
        case .needsMultipleDesktops: "MegaMap needs multiple desktops"
        case .noDesktops: "No desktops available"
        }
    }

    var message: String {
        switch self {
        case .loading:
            "MegaMap will appear here when desktop data is ready."
        case .desktopDataUnavailable:
            "Check TilePilot’s System tab for the connection to yabai, then try Refresh."
        case .needsMultipleDesktops:
            "Add another desktop to a display in Mission Control, then choose Refresh."
        case .noDesktops:
            "Choose Refresh to check for desktops again."
        }
    }
}
