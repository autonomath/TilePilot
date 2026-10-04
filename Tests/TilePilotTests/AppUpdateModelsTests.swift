#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class AppUpdateModelsTests: XCTestCase {
    func testNormalizedAppVersionStripsLeadingV() {
        XCTAssertEqual(normalizedAppVersionString(from: "v0.2.12"), "0.2.12")
    }

    func testVersionComparisonPadsMissingComponents() {
        XCTAssertEqual(AppVersion("0.2.12"), AppVersion("0.2.12.0"))
        XCTAssertTrue(AppVersion("0.2.13")! > AppVersion("0.2.12.9")!)
    }

    func testVersionComparisonIgnoresTrailingNonNumericSuffix() {
        XCTAssertEqual(normalizedAppVersionString(from: "v0.2.12-beta"), "0.2.12")
    }
}
#endif
