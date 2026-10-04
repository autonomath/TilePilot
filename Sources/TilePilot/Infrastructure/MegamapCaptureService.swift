import AppKit
import CoreGraphics
import Foundation

final class MegamapCaptureService {
    struct ScreenDescriptor: Sendable {
        let displayID: CGDirectDisplayID
        let localizedName: String
        let frame: CGRect
        let visibleFrame: CGRect
    }

    struct CapturedImagePayload {
        let displayID: Int
        let displayName: String
        let displayAspectRatio: Double
        let desktopIndex: Int
        let capturedFrame: CGRect
        let capturedAt: Date
        let cgImage: CGImage
    }

    func screenRecordingAuthorized() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func removeCapture(at path: String) {
        if MegamapTransientCaptureStore.shared.contains(path) {
            MegamapTransientCaptureStore.shared.removeImage(for: path)
            return
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    func captureExists(at identifier: String) -> Bool {
        if MegamapTransientCaptureStore.shared.contains(identifier) {
            return true
        }
        return FileManager.default.fileExists(atPath: identifier)
    }

    func removeAllPersistedCapturesFromDisk() {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return
        }
        let directory = base
            .appendingPathComponent("TilePilot", isDirectory: true)
            .appendingPathComponent("Megamap", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    func capture(display: DisplayState, desktopIndex: Int) throws -> MegamapCaptureRecord {
        guard let screen = resolveScreenDescriptor(for: display) else {
            throw NSError(
                domain: "MegamapCaptureService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not match display \(display.name) to a macOS screen."]
            )
        }
        return try persist(capturedPayload(display: display, desktopIndex: desktopIndex, screen: screen))
    }

    func capture(display: DisplayState, desktopIndex: Int, screen: ScreenDescriptor) throws -> MegamapCaptureRecord {
        try persist(capturedPayload(display: display, desktopIndex: desktopIndex, screen: screen))
    }

    func capturedPayload(display: DisplayState, desktopIndex: Int, screen: ScreenDescriptor) throws -> CapturedImagePayload {
        let captureRect = captureRect(for: screen)
        let cgImage: CGImage?
        if let captureRect {
            cgImage = CGDisplayCreateImage(screen.displayID, rect: captureRect)
        } else {
            cgImage = CGDisplayCreateImage(screen.displayID)
        }
        guard let cgImage else {
            throw NSError(
                domain: "MegamapCaptureService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Screen capture returned no image for \(display.name)."]
            )
        }

        return CapturedImagePayload(
            displayID: display.id,
            displayName: display.name,
            displayAspectRatio: captureAspectRatio(for: screen, fallbackDisplay: display),
            desktopIndex: desktopIndex,
            capturedFrame: captureFrame(for: screen, fallbackDisplay: display),
            capturedAt: Date(),
            cgImage: cgImage
        )
    }

    func persist(_ payload: CapturedImagePayload) throws -> MegamapCaptureRecord {
        let captureIdentifier = "memory://display-\(payload.displayID)-desktop-\(payload.desktopIndex)-\(Int(payload.capturedAt.timeIntervalSince1970))"
        MegamapTransientCaptureStore.shared.store(payload.cgImage, for: captureIdentifier)

        return MegamapCaptureRecord(
            displayID: payload.displayID,
            displayName: payload.displayName,
            displayAspectRatio: payload.displayAspectRatio,
            desktopIndex: payload.desktopIndex,
            capturedFrameX: payload.capturedFrame.origin.x,
            capturedFrameY: payload.capturedFrame.origin.y,
            capturedFrameW: payload.capturedFrame.size.width,
            capturedFrameH: payload.capturedFrame.size.height,
            screenshotPath: captureIdentifier,
            capturedAt: payload.capturedAt
        )
    }

    func resolveScreenDescriptors(for displays: [DisplayState]) -> [Int: ScreenDescriptor] {
        let availableScreens = currentScreenDescriptors()
        guard !availableScreens.isEmpty else { return [:] }
        var resolved: [Int: ScreenDescriptor] = [:]
        for display in displays {
            if let descriptor = bestScreenDescriptor(for: display, from: availableScreens) {
                resolved[display.id] = descriptor
            }
        }
        return resolved
    }

    private func resolveScreenDescriptor(for display: DisplayState) -> ScreenDescriptor? {
        bestScreenDescriptor(for: display, from: currentScreenDescriptors())
    }

    private func currentScreenDescriptors() -> [ScreenDescriptor] {
        NSScreen.screens.compactMap { screen -> ScreenDescriptor? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return ScreenDescriptor(
                displayID: CGDirectDisplayID(number.uint32Value),
                localizedName: {
                    if #available(macOS 10.15, *) {
                        return screen.localizedName
                    }
                    return "Display"
                }(),
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
    }

    private func captureRect(for screen: ScreenDescriptor) -> CGRect? {
        nil
    }

    private func captureAspectRatio(for screen: ScreenDescriptor, fallbackDisplay: DisplayState) -> Double {
        let frame = captureFrame(for: screen, fallbackDisplay: fallbackDisplay)
        return max(frame.width, 1) / max(frame.height, 1)
    }

    private func captureFrame(for screen: ScreenDescriptor, fallbackDisplay: DisplayState) -> CGRect {
        return CGRect(
            x: fallbackDisplay.frameX,
            y: fallbackDisplay.frameY,
            width: fallbackDisplay.frameW,
            height: fallbackDisplay.frameH
        )
    }

    private func bestScreenDescriptor(for display: DisplayState, from descriptors: [ScreenDescriptor]) -> ScreenDescriptor? {
        let targetFrame = CGRect(x: display.frameX, y: display.frameY, width: display.frameW, height: display.frameH)
        var best: ScreenDescriptor?
        var bestScore: CGFloat = -.greatestFiniteMagnitude

        for descriptor in descriptors {
            let intersection = descriptor.frame.intersection(targetFrame)
            let overlapArea = intersection.isNull ? 0 : (intersection.width * intersection.height)
            let exactNameBonus: CGFloat = descriptor.localizedName == display.name ? 1_000_000 : 0
            let exactFrameBonus: CGFloat = descriptor.frame.equalTo(targetFrame) ? 2_000_000 : 0
            let score = overlapArea + exactNameBonus + exactFrameBonus
            if score > bestScore {
                bestScore = score
                best = descriptor
            }
        }

        return best
    }
}
