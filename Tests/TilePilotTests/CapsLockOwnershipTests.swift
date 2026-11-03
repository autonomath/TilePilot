#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class CapsLockOwnershipTests: XCTestCase {
    private let capsLock: UInt64 = 0x7_0000_0039
    private let f18: UInt64 = 0x7_0000_006D
    private let f20: UInt64 = 0x7_0000_006F
    private let rightOption: UInt64 = 0x7_0000_00E6
    private let leftControl: UInt64 = 0x7_0000_00E0

    func testRaycastHyperKeyIsItsLiveCapsLockMapping() {
        XCTAssertEqual(owner(mappings: [[entry(capsLock, f20)]], raycastRunning: true), .raycastHyperKey)
        // Turning the Hyper Key off empties the mapping, whatever Raycast's saved preference says.
        XCTAssertNil(owner(mappings: [[]], raycastRunning: true))
    }

    func testKarabinerEngineOwnsIt() {
        XCTAssertEqual(owner(karabinerRunning: true), .karabiner)
        XCTAssertTrue(CapsLockOwnership.isKarabinerEngine(processName: "Karabiner-Core-S"))
        XCTAssertTrue(CapsLockOwnership.isKarabinerEngine(processName: "karabiner_grabbe"))
        XCTAssertFalse(CapsLockOwnership.isKarabinerEngine(processName: "Karabiner-Menu"))
        XCTAssertFalse(CapsLockOwnership.isKarabinerEngine(processName: "karabiner_consol"))
    }

    func testAnyOtherCapsLockRemapOwnsIt() {
        XCTAssertEqual(owner(mappings: [[entry(capsLock, f20)]]), .otherRemap)
        XCTAssertEqual(owner(mappings: [[entry(capsLock, leftControl)]], raycastRunning: true), .otherRemap)
        XCTAssertNil(owner(mappings: [[entry(rightOption, leftControl)], []]))
    }

    func testTilePilotsOwnEntryCountsOnlyWhileTilePilotRemembersAddingIt() {
        XCTAssertNil(owner(mappings: [[entry(capsLock, f18)]], applied: true))
        XCTAssertEqual(owner(mappings: [[entry(capsLock, f18)]], applied: false), .otherRemap)
    }

    func testAddingKeepsOtherEntriesAndNeverOverwritesCapsLock() throws {
        let other = entry(rightOption, leftControl)

        let added = try XCTUnwrap(CapsLockOwnership.addingTilePilotEntry(to: [other]))
        XCTAssertEqual(added.map(pair), [pair(other), [capsLock, f18]])
        XCTAssertTrue(CapsLockOwnership.hasTilePilotEntry(added))
        XCTAssertNil(CapsLockOwnership.addingTilePilotEntry(to: [entry(capsLock, f20)]))
        XCTAssertNil(CapsLockOwnership.addingTilePilotEntry(to: added))
    }

    func testRemovingTakesOnlyTilePilotsEntry() throws {
        let other = entry(rightOption, leftControl)

        let removed = try XCTUnwrap(CapsLockOwnership.removingTilePilotEntry(from: [other, entry(capsLock, f18)]))
        XCTAssertEqual(removed.map(pair), [pair(other)])
        XCTAssertNil(CapsLockOwnership.removingTilePilotEntry(from: [other, entry(capsLock, f20)]))
    }

    private func owner(
        mappings: [[[String: Any]]] = [],
        applied: Bool = false,
        raycastRunning: Bool = false,
        karabinerRunning: Bool = false
    ) -> CapsLockOwner? {
        CapsLockOwnership.owner(
            keyboardMappings: mappings,
            tilePilotApplied: applied,
            raycastRunning: raycastRunning,
            karabinerRunning: karabinerRunning
        )
    }

    private func entry(_ source: UInt64, _ destination: UInt64) -> [String: Any] {
        [
            CapsLockOwnership.sourceKey: NSNumber(value: source),
            CapsLockOwnership.destinationKey: NSNumber(value: destination),
        ]
    }

    private func pair(_ entry: [String: Any]) -> [UInt64] {
        [
            (entry[CapsLockOwnership.sourceKey] as? NSNumber)?.uint64Value ?? 0,
            (entry[CapsLockOwnership.destinationKey] as? NSNumber)?.uint64Value ?? 0,
        ]
    }
}
#endif
