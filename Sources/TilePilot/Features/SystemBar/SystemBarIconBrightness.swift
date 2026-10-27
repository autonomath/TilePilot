import CoreGraphics
import Foundation

/// Brings icons copied from an inactive display's menu bar back to full brightness.
///
/// macOS draws every icon on an inactive bar at a fixed fraction of its brightness over the bar's
/// background: 28% for third-party template icons, 35% for the system's own icons (clock,
/// Wi-Fi, battery), and 60% for full-color images (measured on macOS 27 with a dark menu bar:
/// dim = background + fraction × (bright − background), within 2 of 255). Each
/// icon's fraction is learned by comparing a copy taken while its bar was active with one taken
/// while it was not, and kept only when it matches one of those fractions, so an icon whose
/// content changed in between, or a bar caught mid-fade, never teaches a wrong value. Icons
/// without a learned fraction are shown as macOS draws them.
struct SystemBarIconBrightness {
    static let knownFactors: [CGFloat] = [0.28, 0.35, 0.6]
    static let snapDistance: CGFloat = 0.04
    /// Channel differences from the background below this are too faint to measure a ratio.
    static let signalThreshold = 60

    /// Learned fractions by icon (row keys, see SystemBarIconRowState.rowKey).
    private(set) var factors: [String: CGFloat]
    /// The newest copy of each icon taken while its bar was active.
    private var references: [String: CGImage] = [:]
    private var learnedFrom: [String: CGImage] = [:]
    private var cache: [String: (source: CGImage, result: CGImage)] = [:]

    init(factors: [String: CGFloat] = [:]) {
        self.factors = factors
    }

    /// Notes a copy taken while the icon's bar was active.
    mutating func noteBright(_ image: CGImage, key: String) {
        references[key] = image
    }

    /// `image`, copied from an inactive bar, at full brightness; nil while the icon's fraction is
    /// unknown.
    mutating func brightened(_ image: CGImage, key: String) -> CGImage? {
        if let reference = references[key], learnedFrom[key] !== reference {
            learnedFrom[key] = reference
            if let factor = Self.learnFactor(bright: reference, dim: image) {
                factors[key] = factor
                cache[key] = nil
            }
        }
        if let cached = cache[key], cached.source === image {
            return cached.result
        }
        guard let factor = factors[key], let result = Self.brighten(image, factor: factor) else { return nil }
        cache[key] = (image, result)
        return result
    }

    /// Drops the copies of icons that are gone; learned fractions stay.
    mutating func keepOnly(_ keys: Set<String>) {
        references = references.filter { keys.contains($0.key) }
        learnedFrom = learnedFrom.filter { keys.contains($0.key) }
        cache = cache.filter { keys.contains($0.key) }
    }

    // MARK: - Pixels

    private struct Pixels {
        var bytes: [UInt8]
        let width: Int
        let height: Int
        let colorSpace: CGColorSpace
    }

    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// BGRA bytes in the image's own color space, so nothing is converted.
    private static func pixels(of image: CGImage) -> Pixels? {
        let width = image.width, height = image.height
        guard width > 2, height > 2 else { return nil }
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: bitmapInfo
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Pixels(bytes: bytes, width: width, height: height, colorSpace: colorSpace) : nil
    }

    /// The bar's background per channel (B, G, R): the median of the image's border, which icon
    /// copies leave as padding.
    private static func background(_ pixels: Pixels) -> [Int] {
        var border: [Int] = []
        for x in 0..<pixels.width {
            border.append(x)
            border.append((pixels.height - 1) * pixels.width + x)
        }
        for y in 1..<(pixels.height - 1) {
            border.append(y * pixels.width)
            border.append(y * pixels.width + pixels.width - 1)
        }
        return (0..<3).map { channel in
            let values = border.map { Int(pixels.bytes[$0 * 4 + channel]) }.sorted()
            return values[values.count / 2]
        }
    }

    /// The fraction macOS dimmed `dim` by, when the two copies agree on most of the icon and the
    /// ratio matches a known fraction.
    static func learnFactor(bright: CGImage, dim: CGImage) -> CGFloat? {
        guard bright.width == dim.width, bright.height == dim.height,
              let brightPixels = pixels(of: bright), let dimPixels = pixels(of: dim) else { return nil }
        let brightBackground = background(brightPixels)
        let dimBackground = background(dimPixels)
        var samples: [(bright: Int, dim: Int)] = []
        for index in 0..<(brightPixels.width * brightPixels.height) {
            for channel in 0..<3 {
                let signal = Int(brightPixels.bytes[index * 4 + channel]) - brightBackground[channel]
                guard abs(signal) >= signalThreshold else { continue }
                samples.append((signal, Int(dimPixels.bytes[index * 4 + channel]) - dimBackground[channel]))
            }
        }
        guard samples.count >= 20 else { return nil }
        let ratios = samples.map { CGFloat($0.dim) / CGFloat($0.bright) }.sorted()
        let median = ratios[ratios.count / 2]
        guard let known = knownFactors.min(by: { abs($0 - median) < abs($1 - median) }),
              abs(known - median) <= snapDistance else { return nil }
        let agreeing = samples.filter { abs(CGFloat($0.dim) - known * CGFloat($0.bright)) <= 6 }.count
        return agreeing * 10 >= samples.count * 7 ? known : nil
    }

    /// Undoes a known dimming: background + (pixel − background) ÷ fraction.
    static func brighten(_ image: CGImage, factor: CGFloat) -> CGImage? {
        guard factor > 0, factor < 1, var pixels = pixels(of: image) else { return nil }
        let base = background(pixels)
        let gain = 1 / factor
        for index in 0..<(pixels.width * pixels.height) {
            let alpha = Int(pixels.bytes[index * 4 + 3])
            for channel in 0..<3 {
                let offset = index * 4 + channel
                let value = CGFloat(base[channel]) + CGFloat(Int(pixels.bytes[offset]) - base[channel]) * gain
                pixels.bytes[offset] = UInt8(min(max(value.rounded(), 0), CGFloat(alpha)))
            }
        }
        let width = pixels.width, height = pixels.height
        return pixels.bytes.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: pixels.colorSpace, bitmapInfo: bitmapInfo
            )?.makeImage()
        }
    }
}
