import CoreGraphics

/// Picks the window to focus in a direction from where windows sit. yabai only finds neighbours
/// among tiled windows, so floating grids (Windows picker, Templates) need this. Frames use
/// yabai's top-left origin.
enum DirectionalFocusPlanner {
    /// `windows` run front to back. A window hidden behind ones in front of it (checked on a 5×5 grid
    /// of points, so a strip still showing counts) is skipped. Ties go to the window further front.
    static func target(
        from currentID: Int,
        toward direction: DirectionalShortcutDirection,
        among windows: [(id: Int, frame: CGRect)]
    ) -> Int? {
        guard let current = windows.first(where: { $0.id == currentID })?.frame else { return nil }
        var best: (id: Int, score: CGFloat)?
        for (index, window) in windows.enumerated() where window.id != currentID {
            let frame = window.frame
            let inFront = windows[..<index].map(\.frame)
            let steps: [CGFloat] = [0.1, 0.3, 0.5, 0.7, 0.9]
            let samples = steps.flatMap { x in steps.map { y in CGPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y) } }
            guard samples.contains(where: { point in !inFront.contains { $0.contains(point) } }) else { continue }

            let dx = frame.midX - current.midX
            let dy = frame.midY - current.midY
            let (along, across): (CGFloat, CGFloat)
            switch direction {
            case .left: (along, across) = (-dx, dy)
            case .right: (along, across) = (dx, dy)
            case .up: (along, across) = (-dy, dx)
            case .down: (along, across) = (dy, dx)
            }
            guard along > 1 else { continue }
            // Off-axis distance counts double, so the window in the same row or column wins.
            let score = along + 2 * abs(across)
            if best.map({ score < $0.score }) ?? true { best = (window.id, score) }
        }
        return best?.id
    }
}
