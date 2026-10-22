import ApplicationServices
import CoreGraphics
import Foundation

/// Reads windows' real frames through Accessibility, matched by window ID. Mission Control, App
/// Exposé, and Show Desktop change what the window server reports but leave these frames alone.
enum AccessibilityWindowFrames {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// `_AXUIElementGetWindow` is private but stable; yabai and most window managers rely on it.
    /// Without it TilePilot falls back to comparing yabai's frames.
    private static let getWindow: GetWindow? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            RTLD_NOW | RTLD_LOCAL
        ),
            let address = dlsym(handle, "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(address, to: GetWindow.self)
    }()

    /// Frames keyed by window ID for the requested windows of each app. Slow or hung apps get
    /// a short timeout and are left out.
    static func frames(windowIDsByPID: [Int: Set<Int>]) -> [Int: CGRect] {
        guard let getWindow else { return [:] }
        var result: [Int: CGRect] = [:]
        for (pid, windowIDs) in windowIDsByPID where pid > 0 && !windowIDs.isEmpty {
            let app = AXUIElementCreateApplication(pid_t(pid))
            AXUIElementSetMessagingTimeout(app, 0.3)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else {
                continue
            }
            for window in windows {
                var windowID = CGWindowID(0)
                guard getWindow(window, &windowID) == .success,
                      windowIDs.contains(Int(windowID)),
                      let frame = frame(of: window) else {
                    continue
                }
                result[Int(windowID)] = frame
            }
        }
        return result
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }
}
