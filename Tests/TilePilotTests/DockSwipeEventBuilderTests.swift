#if canImport(XCTest)
import CoreGraphics
import Darwin
import XCTest
@testable import TilePilot

final class DockSwipeEventBuilderTests: XCTestCase {
    @MainActor
    func testModernGestureCarriesHIDProgressThroughCGEventCopy() throws {
        guard #available(macOS 27, *) else { throw XCTSkip("macOS 27 HID gesture format") }
        let reader = try HIDReader()
        for phase in [Int64(1), 2] {
            let events = try XCTUnwrap(DockSwipeEventBuilder.makeEvents(
                originOffset: -0.42, phase: phase, exitSpeed: nil, type: 1, invertedFromDevice: false
            ), DockSwipeEventBuilder.unavailableReason ?? "No event")
            XCTAssertEqual(events.count, 1)
            let copiedEvent = try XCTUnwrap(events.first?.copy())
            XCTAssertEqual(copiedEvent.type.rawValue, 30)
            let hid = try XCTUnwrap(reader.copyEmbedded(copiedEvent)?.takeRetainedValue())
            XCTAssertEqual(reader.type(hid), 23)
            XCTAssertEqual(reader.phase(hid), UInt32(phase))
            XCTAssertEqual(reader.integer(hid, 23 << 16 | 1), 1)
            XCTAssertEqual(reader.integer(hid, 23 << 16 | 5), 3)
            XCTAssertEqual(reader.float(hid, 23 << 16 | 2), -0.42, accuracy: 1.0 / 65_536)
            XCTAssertTrue(reader.children(hid).map { CFArrayGetCount($0) == 0 } ?? true)
        }
    }

    @MainActor
    func testModernEndAndCancelPreserveProgressAndVelocity() throws {
        guard #available(macOS 27, *) else { throw XCTSkip("macOS 27 HID gesture format") }
        let reader = try HIDReader()
        for phase in [Int64(4), 8] {
            let events = try XCTUnwrap(DockSwipeEventBuilder.makeEvents(
                originOffset: 0.6, phase: phase, exitSpeed: 1.25, type: 1, invertedFromDevice: false
            ))
            let hid = try XCTUnwrap(reader.copyEmbedded(try XCTUnwrap(events.first))?.takeRetainedValue())
            XCTAssertEqual(reader.phase(hid), UInt32(phase))
            XCTAssertEqual(reader.float(hid, 23 << 16 | 2), 0.6, accuracy: 1.0 / 65_536)
            let children = try XCTUnwrap(reader.children(hid))
            XCTAssertEqual(CFArrayGetCount(children), 1)
            let childPointer = try XCTUnwrap(CFArrayGetValueAtIndex(children, 0))
            let velocity = Unmanaged<CFTypeRef>.fromOpaque(childPointer).takeUnretainedValue()
            XCTAssertEqual(reader.type(velocity), 9)
            XCTAssertEqual(reader.float(velocity, 9 << 16), 1.25)
            XCTAssertEqual(reader.float(velocity, 9 << 16 | 1), 1.25)
            XCTAssertEqual(reader.float(velocity, 9 << 16 | 2), 0)
        }
    }

    @MainActor
    func testModernDeviceInversionChangesProgressSign() throws {
        guard #available(macOS 27, *) else { throw XCTSkip("macOS 27 HID gesture format") }
        let reader = try HIDReader()
        let events = try XCTUnwrap(DockSwipeEventBuilder.makeEvents(
            originOffset: 0.5, phase: 2, exitSpeed: nil, type: 1, invertedFromDevice: true
        ))
        let hid = try XCTUnwrap(reader.copyEmbedded(try XCTUnwrap(events.first))?.takeRetainedValue())
        XCTAssertEqual(reader.float(hid, 23 << 16 | 2), -0.5)
    }

    @MainActor
    func testLegacyWireFormatPreservesEventOrderAndFloatBits() throws {
        let events = try XCTUnwrap(DockSwipeEventBuilder.makeLegacyEvents(
            originOffset: -0.375, phase: 4, exitSpeed: -1.5, type: 1, invertedFromDevice: true
        ))
        XCTAssertEqual(events.map { $0.type.rawValue }, [30, 29])
        let event = events[0]
        func field(_ number: UInt32) -> CGEventField { CGEventField(rawValue: number)! }
        XCTAssertEqual(event.getDoubleValueField(field(110)), 23)
        XCTAssertEqual(event.getDoubleValueField(field(132)), 4)
        XCTAssertEqual(event.getDoubleValueField(field(124)), -0.375)
        XCTAssertEqual(event.getIntegerValueField(field(135)), Int64(Float32(-0.375).bitPattern))
        XCTAssertEqual(event.getIntegerValueField(field(136)), 1)
        XCTAssertEqual(event.getDoubleValueField(field(129)), -1.5)
    }

    @MainActor
    func testInvalidGestureDoesNotProduceEvents() {
        XCTAssertNil(DockSwipeEventBuilder.makeEvents(
            originOffset: .nan, phase: 1, exitSpeed: nil, type: 1, invertedFromDevice: false
        ))
        XCTAssertNotNil(DockSwipeEventBuilder.unavailableReason)
        XCTAssertNil(DockSwipeEventBuilder.makeEvents(
            originOffset: 0.1, phase: 0, exitSpeed: nil, type: 1, invertedFromDevice: false
        ))
    }

    private struct HIDReader {
        typealias CopyEmbedded = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
        typealias GetUInt = @convention(c) (CFTypeRef) -> UInt32
        typealias GetInteger = @convention(c) (CFTypeRef, UInt32) -> Int
        typealias GetFloat = @convention(c) (CFTypeRef, UInt32) -> Double
        typealias GetChildren = @convention(c) (CFTypeRef) -> CFArray?

        let copyEmbedded: CopyEmbedded
        let type: GetUInt
        let phase: GetUInt
        let integer: GetInteger
        let float: GetFloat
        let children: GetChildren

        init() throws {
            let ioKit = try XCTUnwrap(dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL))
            let coreGraphics = try XCTUnwrap(dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW | RTLD_LOCAL))
            func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as: T.Type) throws -> T {
                unsafeBitCast(try XCTUnwrap(dlsym(handle, name), name), to: T.self)
            }
            copyEmbedded = try symbol(coreGraphics, "CGEventCopyIOHIDEvent", as: CopyEmbedded.self)
            type = try symbol(ioKit, "IOHIDEventGetType", as: GetUInt.self)
            phase = try symbol(ioKit, "IOHIDEventGetPhase", as: GetUInt.self)
            integer = try symbol(ioKit, "IOHIDEventGetIntegerValue", as: GetInteger.self)
            float = try symbol(ioKit, "IOHIDEventGetFloatValue", as: GetFloat.self)
            children = try symbol(ioKit, "IOHIDEventGetChildren", as: GetChildren.self)
        }
    }
}
#endif
