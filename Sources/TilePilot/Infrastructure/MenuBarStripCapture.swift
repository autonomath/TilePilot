import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// Streams one display's real menu bar so mirrored icons look exactly like the originals.
/// The owner registers regions (one per icon, plus a background sample); on each new frame only
/// regions whose pixels changed are copied out, converted once into plain 8-bit images, and
/// reported. Pixels live in memory only and are never written anywhere.
final class MenuBarStripCapture: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate {
    enum State: Equatable, Sendable {
        case idle
        case starting
        case running
        case stopped(reason: String)
    }

    let displayID: CGDirectDisplayID
    /// The menu bar strip in the display's own point coordinates (origin at the display's top-left).
    let stripRect: CGRect
    let scale: CGFloat
    /// Region images are converted into this color space so drawing them is a plain copy.
    let targetColorSpace: CGColorSpace

    private let lock = NSLock()
    private var stream: SCStream?
    private var currentState: State = .idle
    private var regions: [String: CGRect] = [:]
    private var fingerprints: [String: UInt64] = [:]
    private var images: [String: CGImage] = [:]
    /// The stretch of the bar that holds the icons (points relative to the strip), watched for
    /// icons moving (see SystemBarLayoutSignature): its last fingerprint and signature, and how
    /// many layout changes were seen.
    private var layoutRegion: CGRect?
    private var layoutFingerprint: UInt64?
    private var layoutSignature: SystemBarLayoutSignature?
    private var layoutChangeCount = 0
    /// The newest frame, kept so regions registered later can be filled without waiting for the
    /// display to change. Only one buffer is held.
    private var lastPixelBuffer: CVPixelBuffer?
    private let outputQueue = DispatchQueue(label: "com.klode.tilepilot.system-bar.capture", qos: .utility)
    private let onChange: @Sendable () -> Void

    init(
        displayID: CGDirectDisplayID,
        stripRect: CGRect,
        scale: CGFloat,
        targetColorSpace: CGColorSpace?,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.displayID = displayID
        self.stripRect = stripRect
        self.scale = max(1, scale)
        self.targetColorSpace = targetColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.onChange = onChange
        super.init()
    }

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    var isRunning: Bool {
        state == .running
    }

    var isStartingOrRunning: Bool {
        switch state {
        case .starting, .running: return true
        case .idle, .stopped: return false
        }
    }

    /// Call before `start()` so a concurrent health check does not mistake a new capture for a dead one.
    func markStarting() {
        setState(.starting)
    }

    /// The latest pixels of a registered region, or nil before the first frame.
    func image(for key: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[key]
    }

    var regionSummary: String {
        lock.lock()
        defer { lock.unlock() }
        return "regions \(regions.count), images \(images.count), frame kept \(lastPixelBuffer != nil)"
    }

    /// Replaces the tracked regions (rectangles in points relative to the strip's top-left).
    /// New or moved regions are filled from the newest frame right away.
    func setRegions(_ newRegions: [String: CGRect]) {
        lock.lock()
        guard newRegions != regions else {
            lock.unlock()
            return
        }
        for (key, rect) in regions where newRegions[key] != rect {
            fingerprints[key] = nil
            images[key] = nil
        }
        regions = newRegions
        let hasFrame = lastPixelBuffer != nil
        lock.unlock()
        guard hasFrame else { return }
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let buffer = self.lastPixelBuffer
            self.lock.unlock()
            if let buffer {
                self.process(buffer)
            }
        }
    }

    /// Watches `rect` (points relative to the strip) for icons moving, appearing, or
    /// disappearing; nil stops watching. A new stretch is measured from the newest frame without
    /// counting as a change.
    func setLayoutRegion(_ rect: CGRect?) {
        lock.lock()
        guard rect != layoutRegion else {
            lock.unlock()
            return
        }
        layoutRegion = rect
        layoutFingerprint = nil
        layoutSignature = nil
        let hasFrame = lastPixelBuffer != nil
        lock.unlock()
        guard hasFrame, rect != nil else { return }
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let buffer = self.lastPixelBuffer
            self.lock.unlock()
            if let buffer {
                self.process(buffer)
            }
        }
    }

    /// How many layout changes the watched stretch has shown, and how many icon spans it held when
    /// last measured (nil before the first measurement).
    var layoutWatch: (changes: Int, spans: Int?) {
        lock.lock()
        defer { lock.unlock() }
        return (layoutChangeCount, layoutSignature?.spans.count)
    }

    func start() async throws {
        do {
            try await startStream()
        } catch {
            setState(.stopped(reason: error.localizedDescription))
            throw error
        }
    }

    private func startStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = stripRect
        configuration.width = Int((stripRect.width * scale).rounded())
        configuration.height = Int((stripRect.height * scale).rounded())
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        storeStream(stream)
    }

    func stop() async {
        guard let current = takeStream() else { return }
        try? await current.stopCapture()
    }

    /// Development only: ends the stream the way macOS does when its display goes away, keeping
    /// the last images like `stream(_:didStopWithError:)`.
    func simulateUnexpectedStop() async {
        let current = lock.withLock { stream }
        try? await current?.stopCapture()
        lock.withLock {
            currentState = .stopped(reason: "simulated display change")
            stream = nil
            lastPixelBuffer = nil
        }
        onChange()
    }

    private func storeStream(_ stream: SCStream) {
        lock.lock()
        self.stream = stream
        currentState = .running
        lock.unlock()
    }

    private func setState(_ state: State) {
        lock.lock()
        currentState = state
        lock.unlock()
    }

    private func takeStream() -> SCStream? {
        lock.lock()
        defer { lock.unlock() }
        let current = stream
        stream = nil
        currentState = .stopped(reason: "stopped")
        images = [:]
        fingerprints = [:]
        lastPixelBuffer = nil
        return current
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let rawStatus = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: rawStatus),
           status != .complete {
            return
        }
        lock.lock()
        lastPixelBuffer = pixelBuffer
        lock.unlock()
        process(pixelBuffer)
    }

    /// Hashes every registered region and converts only the ones that changed. Runs on the
    /// capture queue.
    private func process(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let currentRegions = regions
        let knownFingerprints = fingerprints
        let layout = layoutRegion
        let knownLayoutFingerprint = layoutFingerprint
        lock.unlock()
        guard !currentRegions.isEmpty || layout != nil else { return }

        var changed: [String: (rect: CGRect, fingerprint: UInt64)] = [:]
        var measuredLayout: (fingerprint: UInt64, signature: SystemBarLayoutSignature)?
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return }
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for (key, rect) in currentRegions {
                let pixels = pixelRect(rect, width: width, height: height)
                guard !pixels.isEmpty else { continue }
                let fingerprint = Self.fingerprint(base: base, bytesPerRow: bytesPerRow, rect: pixels)
                if knownFingerprints[key] != fingerprint {
                    changed[key] = (pixels, fingerprint)
                }
            }
            if let layout {
                let pixels = pixelRect(layout, width: width, height: height)
                let fingerprint = pixels.isEmpty ? nil : Self.fingerprint(base: base, bytesPerRow: bytesPerRow, rect: pixels)
                if let fingerprint, fingerprint != knownLayoutFingerprint {
                    let signature = SystemBarLayoutSignature.measure(bgra: base, bytesPerRow: bytesPerRow, pixelRect: pixels, scale: scale, originX: layout.minX)
                    measuredLayout = (fingerprint, signature)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        var layoutChanged = false
        if let measuredLayout {
            lock.lock()
            if layoutRegion == layout {
                layoutFingerprint = measuredLayout.fingerprint
                if let previous = layoutSignature, measuredLayout.signature.differs(from: previous) {
                    layoutChangeCount += 1
                    layoutChanged = true
                }
                layoutSignature = measuredLayout.signature
            }
            lock.unlock()
        }
        guard !changed.isEmpty else {
            if layoutChanged {
                onChange()
            }
            return
        }

        var frameImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &frameImage)
        guard let frameImage else { return }
        var newImages: [String: CGImage] = [:]
        for (key, entry) in changed {
            guard let crop = frameImage.cropping(to: entry.rect), let flat = flattened(crop) else { continue }
            newImages[key] = flat
        }

        lock.lock()
        for (key, entry) in changed where regions[key] != nil && newImages[key] != nil {
            fingerprints[key] = entry.fingerprint
            images[key] = newImages[key]
        }
        lock.unlock()
        onChange()
    }

    private func pixelRect(_ rect: CGRect, width: Int, height: Int) -> CGRect {
        let pixels = CGRect(
            x: (rect.minX * scale).rounded(.down),
            y: (rect.minY * scale).rounded(.down),
            width: (rect.width * scale).rounded(.up),
            height: (rect.height * scale).rounded(.up)
        )
        let clipped = pixels.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        return clipped.isNull || clipped.width < 1 || clipped.height < 1 ? .zero : clipped
    }

    /// Copies a region into ordinary 8-bit memory in the target color space. Images that still
    /// point at the capture surface are color-converted again on every draw and keep the
    /// stream's buffers alive.
    private func flattened(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: targetColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// FNV-1a over every other row and every other pixel of a BGRA region.
    private static func fingerprint(base: UnsafeMutableRawPointer, bytesPerRow: Int, rect: CGRect) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        var row = Int(rect.minY)
        let maxRow = Int(rect.maxY)
        let minColumn = Int(rect.minX)
        let maxColumn = Int(rect.maxX)
        while row < maxRow {
            let pixels = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            var column = minColumn
            while column < maxColumn {
                hash = (hash ^ UInt64(pixels[column])) &* 0x100000001b3
                column += 2
            }
            row += 2
        }
        return hash
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        currentState = .stopped(reason: error.localizedDescription)
        self.stream = nil
        lastPixelBuffer = nil
        lock.unlock()
        onChange()
    }

    enum CaptureError: LocalizedError {
        case displayUnavailable

        var errorDescription: String? {
            switch self {
            case .displayUnavailable: return "the display is not available for capture"
            }
        }
    }
}
