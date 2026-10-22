#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class SkhdReloadTargetTests: XCTestCase {
    func testSelectsOnePositiveProcessID() {
        XCTAssertEqual(SkhdReloadTarget.resolve(pgrepOutput: " 11015\n"), .success(11015))
    }

    func testAbsentServiceNeedsExplicitStart() {
        XCTAssertEqual(SkhdReloadTarget.resolve(pgrepOutput: "\n"), .failure(.notRunning))
    }

    func testRejectsMultipleServicesInsteadOfSignalingAll() {
        XCTAssertEqual(SkhdReloadTarget.resolve(pgrepOutput: "11015\n11016\n"), .failure(.multipleInstances))
    }

    func testRejectsProcessGroupsAndInvalidLookupOutput() {
        for output in ["-1", "0", "1", "--help", "11015; echo hello", "abc", "2147483648", "１２"] {
            XCTAssertEqual(SkhdReloadTarget.resolve(pgrepOutput: output), .failure(.invalidProcessList), output)
        }
    }
}
#endif
