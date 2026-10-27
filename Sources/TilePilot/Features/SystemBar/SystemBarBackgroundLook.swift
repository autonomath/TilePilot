import CoreGraphics
import Foundation

/// The one solid color the mirror paints behind its menus and icons, sampled from the empty
/// stretch of the active real bar. A new color is adopted only after it holds for a moment, so
/// the fade macOS runs on a bar that is switching displays never reaches the mirror, and the
/// color is kept while another display is active so the mirror never turns gray.
struct SystemBarBackgroundLook {
    static let settleSeconds: TimeInterval = 1.5

    private(set) var current: (color: CGColor, isDark: Bool)?
    /// The newest sampled look and when it was first seen.
    private var candidate: (color: CGColor, isDark: Bool, since: Date)?
    private var lastSample: CGImage?

    /// Takes a new sample of the active bar's background (nil when there is none right now).
    mutating func update(sample: CGImage?, now: Date = Date()) {
        if let sample, sample !== lastSample {
            lastSample = sample
            if let look = Self.averageLook(sample) {
                if current == nil {
                    current = look
                } else if !Self.sameLook(look.color, candidate?.color) {
                    candidate = (look.color, look.isDark, now)
                }
            }
        }
        if let pending = candidate, now.timeIntervalSince(pending.since) >= Self.settleSeconds {
            if !Self.sameLook(pending.color, current?.color) {
                current = (pending.color, pending.isDark)
            }
            candidate = nil
        }
    }

    mutating func reset() {
        current = nil
        candidate = nil
        lastSample = nil
    }

    /// True when two colors are within 3% per channel (or both missing).
    static func sameLook(_ lhs: CGColor?, _ rhs: CGColor?) -> Bool {
        guard let left = lhs?.components, let right = rhs?.components, left.count >= 3, right.count >= 3 else {
            return lhs == nil && rhs == nil
        }
        return zip(left.prefix(3), right.prefix(3)).allSatisfy { abs($0 - $1) < 0.03 }
    }

    /// The average color of an image and whether it reads as dark.
    static func averageLook(_ image: CGImage) -> (color: CGColor, isDark: Bool)? {
        guard let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return nil }
        let pixel = data.bindMemory(to: UInt8.self, capacity: 4)
        let red = CGFloat(pixel[0]) / 255, green = CGFloat(pixel[1]) / 255, blue = CGFloat(pixel[2]) / 255
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return (CGColor(srgbRed: red, green: green, blue: blue, alpha: 1), luminance < 0.5)
    }
}
