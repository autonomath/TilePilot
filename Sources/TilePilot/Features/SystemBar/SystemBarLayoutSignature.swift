import CoreGraphics

/// Where a real menu bar draws something other than its background: spans of columns, in points
/// from the bar's left edge. Icons moving, appearing, or disappearing change the spans; changes
/// inside an icon (a graph, a clock's digits of the same width) do not. Lets the mirror rescan
/// icon positions only when the bar changed.
struct SystemBarLayoutSignature: Equatable, Sendable {
    /// Gaps up to this many points inside a span belong to the same icon (letters of a title).
    static let mergeGap: CGFloat = 4
    /// Edges may wobble this many points (antialiasing, dimming) without counting as a change.
    static let tolerance = 2
    /// Luminance difference from the background that counts as drawn, out of 255.
    static let inkThreshold = 40

    let spans: [ClosedRange<Int>]

    /// Measures a stretch of a captured bar straight from its BGRA pixels. `pixelRect` is the
    /// stretch in pixels; it starts `originX` points from the bar's left edge and has `scale`
    /// pixels per point. Spans cut by the stretch's left edge are left out.
    static func measure(bgra base: UnsafeRawPointer, bytesPerRow: Int, pixelRect: CGRect, scale: CGFloat, originX: CGFloat) -> SystemBarLayoutSignature {
        let minX = Int(pixelRect.minX), maxX = Int(pixelRect.maxX)
        let minY = Int(pixelRect.minY), maxY = Int(pixelRect.maxY)
        let width = maxX - minX, height = maxY - minY
        guard width > 0, height > 2, scale > 0 else { return SystemBarLayoutSignature(spans: []) }
        let margin = height * 15 / 100
        let top = minY + margin, bottom = maxY - margin
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        @inline(__always) func luminance(_ x: Int, _ y: Int) -> Int {
            let pixel = bytes + y * bytesPerRow + x * 4
            return (Int(pixel[2]) * 299 + Int(pixel[1]) * 587 + Int(pixel[0]) * 114) / 1000
        }
        // The bar's background is by far the most common shade.
        var histogram = [Int](repeating: 0, count: 256)
        var y = top
        while y < bottom {
            var x = minX
            while x < maxX {
                histogram[luminance(x, y)] += 1
                x += 2
            }
            y += 2
        }
        var background = 0
        for shade in 1..<256 where histogram[shade] > histogram[background] {
            background = shade
        }
        let mergePixels = Int((mergeGap * scale).rounded())
        var pixelSpans: [(start: Int, end: Int)] = []
        var x = minX
        while x < maxX {
            var drawn = false
            var row = top
            while row < bottom {
                if abs(luminance(x, row) - background) > inkThreshold {
                    drawn = true
                    break
                }
                row += 1
            }
            if drawn {
                let column = x - minX
                if let last = pixelSpans.last, column - last.end <= mergePixels + 1 {
                    pixelSpans[pixelSpans.count - 1].end = column
                } else {
                    pixelSpans.append((column, column))
                }
            }
            x += 1
        }
        let spans = pixelSpans.filter { $0.start > 0 }.map { span -> ClosedRange<Int> in
            let start = Int((originX + CGFloat(span.start) / scale).rounded())
            let end = Int((originX + CGFloat(span.end + 1) / scale).rounded())
            return start...max(start, end)
        }
        return SystemBarLayoutSignature(spans: spans)
    }

    /// True when icons appeared, disappeared, or moved by more than the tolerance.
    func differs(from other: SystemBarLayoutSignature) -> Bool {
        guard spans.count == other.spans.count else { return true }
        return zip(spans, other.spans).contains { mine, theirs in
            abs(mine.lowerBound - theirs.lowerBound) > Self.tolerance || abs(mine.upperBound - theirs.upperBound) > Self.tolerance
        }
    }
}
