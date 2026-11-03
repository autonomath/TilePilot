import Darwin
import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

/// Adds and removes TilePilot's Caps Lock → F18 remap on every keyboard, and reports whether
/// another tool owns Caps Lock. Uses the HID event system API behind `hidutil`, which needs
/// no admin rights. Main thread only.
final class CapsLockRemapper {
    private static let mappingKey = "UserKeyMapping"
    private var notificationPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private var onKeyboardAttach: (() -> Void)?

    func currentOwner(tilePilotApplied: Bool) -> CapsLockOwner? {
        let mappings = withKeyboardServices { services in services.map(Self.entries(of:)) }
        let processes = Self.processNames()
        return CapsLockOwnership.owner(
            keyboardMappings: mappings,
            tilePilotApplied: tilePilotApplied,
            // Raycast's saved Hyper Key preference goes stale; its live Caps Lock mapping doesn't.
            raycastRunning: processes.contains("Raycast"),
            karabinerRunning: processes.contains(where: CapsLockOwnership.isKarabinerEngine(processName:))
        )
    }

    /// Adds the remap to keyboards that lack it and leaves their other entries alone. Returns
    /// whether at least one keyboard now has it.
    @discardableResult
    func applyTilePilotMapping() -> Bool {
        withKeyboardServices { services in
            var mapped = false
            for service in services {
                if let updated = CapsLockOwnership.addingTilePilotEntry(to: Self.entries(of: service)) {
                    _ = IOHIDServiceClientSetProperty(service, Self.mappingKey as CFString, updated as CFArray)
                }
                if CapsLockOwnership.hasTilePilotEntry(Self.entries(of: service)) { mapped = true }
            }
            return mapped
        }
    }

    /// Removes only TilePilot's entry from every keyboard.
    func removeTilePilotMapping() {
        withKeyboardServices { services in
            for service in services {
                if let updated = CapsLockOwnership.removingTilePilotEntry(from: Self.entries(of: service)) {
                    _ = IOHIDServiceClientSetProperty(service, Self.mappingKey as CFString, updated as CFArray)
                }
            }
        }
    }

    /// Calls the handler on the main thread whenever a keyboard or other HID device appears,
    /// because a newly attached keyboard starts without the remap.
    func watchForKeyboards(_ handler: @escaping () -> Void) {
        onKeyboardAttach = handler
        guard notificationPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            CapsLockRemapper.drain(iterator)
            guard let refcon else { return }
            Unmanaged<CapsLockRemapper>.fromOpaque(refcon).takeUnretainedValue().onKeyboardAttach?()
        }
        let result = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("IOHIDEventService"),
            callback,
            Unmanaged.passUnretained(self).toOpaque(),
            &matchIterator
        )
        // Devices already attached are listed once; draining them arms the notification.
        if result == KERN_SUCCESS { Self.drain(matchIterator) }
    }

    func stopWatchingForKeyboards() {
        if matchIterator != 0 {
            IOObjectRelease(matchIterator)
            matchIterator = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        onKeyboardAttach = nil
    }

    private static func drain(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func withKeyboardServices<T>(_ body: ([IOHIDServiceClient]) -> T) -> T {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []).filter {
            IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0
        }
        return withExtendedLifetime(client) { body(services) }
    }

    private static func entries(of service: IOHIDServiceClient) -> [[String: Any]] {
        IOHIDServiceClientCopyProperty(service, mappingKey as CFString) as? [[String: Any]] ?? []
    }

    /// Every process name, including root daemons such as Karabiner's.
    private static func processNames() -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 32
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else { return [] }
        return processes.prefix(size / MemoryLayout<kinfo_proc>.stride).map { process in
            var name = process.kp_proc.p_comm
            return withUnsafeBytes(of: &name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
    }
}
