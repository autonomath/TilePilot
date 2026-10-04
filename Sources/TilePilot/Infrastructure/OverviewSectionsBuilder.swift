import Foundation

enum OverviewSectionsBuilder {
    static func build(
        snapshot: LiveStateSnapshot,
        isExcluded: (WindowState) -> Bool
    ) -> [OverviewDisplaySection] {
        let sortedDisplays = OverviewDisplayOrdering.verticallyOrdered(snapshot.displays)

        let allWindows = snapshot.windows.filter { !isExcluded($0) }
        let visibleWindows = allWindows.filter { $0.isVisible && !$0.isMinimized && !$0.isHidden }
        let spacesByDisplay = Dictionary(grouping: snapshot.spaces, by: \.displayId)
        let windowsBySpace = Dictionary(grouping: allWindows, by: \.space)
        let visibleWindowCountByDisplay = Dictionary(grouping: visibleWindows, by: \.display).mapValues(\.count)
        let totalWindowCountByDisplay = Dictionary(grouping: allWindows, by: \.display).mapValues(\.count)
        let visibleWindowCountBySpace = Dictionary(grouping: visibleWindows, by: \.space).mapValues(\.count)
        let totalWindowCountBySpace = Dictionary(grouping: allWindows, by: \.space).mapValues(\.count)

        return sortedDisplays.map { display in
            let spaces = (spacesByDisplay[display.id] ?? []).sorted { lhs, rhs in
                if lhs.focused != rhs.focused { return lhs.focused && !rhs.focused }
                if lhs.visible != rhs.visible { return lhs.visible && !rhs.visible }
                return lhs.index < rhs.index
            }
            let sections = spaces.map { space in
                let spaceWindows = (windowsBySpace[space.index] ?? []).sorted { lhs, rhs in
                    if lhs.focused != rhs.focused { return lhs.focused && !rhs.focused }
                    let lhsVisible = lhs.isVisible && !lhs.isMinimized && !lhs.isHidden
                    let rhsVisible = rhs.isVisible && !rhs.isMinimized && !rhs.isHidden
                    if lhsVisible != rhsVisible { return lhsVisible && !rhsVisible }
                    return lhs.id < rhs.id
                }
                return OverviewSpaceSection(
                    id: space.index,
                    space: space,
                    tilingEnabled: (space.layout ?? "").lowercased() != "float",
                    visibleWindowCount: visibleWindowCountBySpace[space.index] ?? 0,
                    totalWindowCount: totalWindowCountBySpace[space.index] ?? 0,
                    windows: spaceWindows
                )
            }

            return OverviewDisplaySection(
                id: display.id,
                display: display,
                visibleWindowCount: visibleWindowCountByDisplay[display.id] ?? 0,
                totalWindowCount: totalWindowCountByDisplay[display.id] ?? 0,
                spaces: sections
            )
        }
    }
}
