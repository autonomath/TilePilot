import CoreGraphics
import Darwin
import Foundation

/// Builds native Dock gestures without posting them or changing desktop state.
/// macOS 27 reads an embedded IOHIDEvent; earlier versions read CGEvent fields.
@MainActor
enum DockSwipeEventBuilder {
    private static let modernRuntime = HIDRuntime.load()
    private static var constructionFailure: String?

    static var unavailableReason: String? {
        if let constructionFailure { return constructionFailure }
        if #available(macOS 27, *), case .failure(let error) = modernRuntime {
            return error.localizedDescription
        }
        return nil
    }

    static func makeEvents(
        originOffset: Double,
        phase: Int64,
        exitSpeed: Double?,
        type: Double,
        invertedFromDevice: Bool
    ) -> [CGEvent]? {
        constructionFailure = nil
        guard originOffset.isFinite, type.isFinite, type == 1,
              [Int64(1), 2, 4, 8].contains(phase), exitSpeed?.isFinite != false else {
            constructionFailure = "Desktop Scrub could not construct a valid desktop gesture."
            return nil
        }
        if #available(macOS 27, *) {
            guard case .success(let runtime) = modernRuntime else { return nil }
            guard let event = runtime.makeEvent(
                originOffset: invertedFromDevice ? -originOffset : originOffset,
                phase: UInt32(phase),
                exitSpeed: exitSpeed
            ) else {
                constructionFailure = "macOS could not construct the native desktop gesture."
                return nil
            }
            return [event]
        }
        return makeLegacyEvents(
            originOffset: originOffset,
            phase: phase,
            exitSpeed: exitSpeed,
            type: type,
            invertedFromDevice: invertedFromDevice
        )
    }

    /// Kept separate so the pre-macOS 27 wire format remains independently testable.
    static func makeLegacyEvents(
        originOffset: Double,
        phase: Int64,
        exitSpeed: Double?,
        type: Double,
        invertedFromDevice: Bool
    ) -> [CGEvent]? {
        guard let gesture = CGEvent(source: nil), let swipe = CGEvent(source: nil) else { return nil }
        func field(_ number: UInt32) -> CGEventField { CGEventField(rawValue: number)! }
        gesture.type = CGEventType(rawValue: 29)!
        gesture.setDoubleValueField(field(41), value: 33231)
        swipe.type = CGEventType(rawValue: 30)!
        swipe.setDoubleValueField(field(41), value: 33231)
        swipe.setDoubleValueField(field(110), value: 23)
        swipe.setDoubleValueField(field(132), value: Double(phase))
        swipe.setDoubleValueField(field(134), value: Double(phase))
        swipe.setDoubleValueField(field(124), value: originOffset)
        swipe.setIntegerValueField(field(135), value: Int64(Float32(originOffset).bitPattern))
        let encodedHorizontalMotion = Double(Float32(bitPattern: 1))
        swipe.setDoubleValueField(field(119), value: encodedHorizontalMotion)
        swipe.setDoubleValueField(field(139), value: encodedHorizontalMotion)
        swipe.setDoubleValueField(field(123), value: type)
        swipe.setDoubleValueField(field(165), value: type)
        swipe.setIntegerValueField(field(136), value: invertedFromDevice ? 1 : 0)
        if let exitSpeed {
            swipe.setDoubleValueField(field(129), value: exitSpeed)
            swipe.setDoubleValueField(field(130), value: exitSpeed)
        }
        return [swipe, gesture]
    }

    private struct RuntimeError: LocalizedError {
        let errorDescription: String?
    }

    private struct HIDRuntime {
        // These private entry points are looked up, never linked or accessed by
        // object-layout offsets. Missing symbols leave the feature unavailable.
        // Wire format reference: Mac Mouse Fix 3.1.0 TouchSimulator.m, lines 187–220.
        // https://github.com/noah-nuebling/mac-mouse-fix/blob/3.1.0/Helper/Core/Touch/TouchSimulator.m
        typealias Create = @convention(c) (CFAllocator?, UInt32, UInt64, UInt32) -> Unmanaged<CFTypeRef>?
        typealias SetInteger = @convention(c) (CFTypeRef, UInt32, Int) -> Void
        typealias SetFloat = @convention(c) (CFTypeRef, UInt32, Double) -> Void
        typealias Append = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
        typealias Embed = @convention(c) (CGEvent, CFTypeRef) -> Void
        typealias CopyEmbedded = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?

        let create: Create
        let setInteger: SetInteger
        let setFloat: SetFloat
        let append: Append
        let embed: Embed
        let copyEmbedded: CopyEmbedded

        static func load() -> Result<Self, RuntimeError> {
            guard let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL),
                  let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL) else {
                return .failure(RuntimeError(errorDescription: "Desktop Scrub cannot load the macOS desktop gesture service."))
            }
            func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as: T.Type) throws -> T {
                guard let address = dlsym(handle, name) else {
                    throw RuntimeError(errorDescription: "Desktop Scrub is unavailable on this macOS version.")
                }
                return unsafeBitCast(address, to: T.self)
            }
            do {
                return .success(try Self(
                    create: symbol(ioKit, "IOHIDEventCreate", as: Create.self),
                    setInteger: symbol(ioKit, "IOHIDEventSetIntegerValue", as: SetInteger.self),
                    setFloat: symbol(ioKit, "IOHIDEventSetFloatValue", as: SetFloat.self),
                    append: symbol(ioKit, "IOHIDEventAppendEvent", as: Append.self),
                    embed: symbol(skyLight, "SLEventSetIOHIDEvent", as: Embed.self),
                    copyEmbedded: symbol(skyLight, "SLEventCopyIOHIDEvent", as: CopyEmbedded.self)
                ))
            } catch let error as RuntimeError {
                return .failure(error)
            } catch {
                return .failure(RuntimeError(errorDescription: "Desktop Scrub could not prepare the macOS desktop gesture service."))
            }
        }

        func makeEvent(originOffset: Double, phase: UInt32, exitSpeed: Double?) -> CGEvent? {
            guard let ownedHID = create(nil, 23, 0, phase << 24) else { return nil }
            let hid = ownedHID.takeRetainedValue()
            guard let event = CGEvent(source: nil) else { return nil }
            let dockFields: UInt32 = 23 << 16
            setInteger(hid, dockFields | 1, 1) // Horizontal motion.
            setInteger(hid, dockFields | 5, 3) // Primary Dock gesture.
            setFloat(hid, dockFields | 2, originOffset)

            if phase == 4 || phase == 8 {
                guard let ownedVelocity = create(nil, 9, 0, 0) else { return nil }
                let velocity = ownedVelocity.takeRetainedValue()
                let velocityFields: UInt32 = 9 << 16
                setFloat(velocity, velocityFields, exitSpeed ?? 0)
                setFloat(velocity, velocityFields | 1, exitSpeed ?? 0)
                setFloat(velocity, velocityFields | 2, 0)
                append(hid, velocity, 0)
            }

            event.type = CGEventType(rawValue: 30)!
            embed(event, hid)
            // Verify the OS retained the payload before reporting construction
            // success. Posting still needs live verification by the coordinator.
            guard let attached = copyEmbedded(event) else { return nil }
            _ = attached.takeRetainedValue()
            return event
        }
    }
}
