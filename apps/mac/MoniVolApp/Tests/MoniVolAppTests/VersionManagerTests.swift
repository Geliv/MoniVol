import XCTest
@testable import MoniVolApp

/// Tests for the pure version comparison helpers in `VersionManager`.
///
/// `driverNeedsUpdate()` depends on the filesystem (installed vs bundled
/// driver plists) and is covered by manual verification instead.
final class VersionManagerTests: XCTestCase {

    // MARK: - isVersionOlder

    func testBasicComparison() {
        XCTAssertTrue(VersionManager.isVersionOlder("1.0.0", than: "1.0.1"))
        XCTAssertTrue(VersionManager.isVersionOlder("1.0.9", than: "1.1.0"))
        XCTAssertFalse(VersionManager.isVersionOlder("1.0.1", than: "1.0.0"))
    }

    func testEqualVersionsAreNotOlder() {
        XCTAssertFalse(VersionManager.isVersionOlder("1.0.5", than: "1.0.5"))
        XCTAssertFalse(VersionManager.isVersionOlder("2.3.4", than: "2.3.4"))
    }

    func testNumericNotLexicographic() {
        // 10 > 9 numerically, but "10" < "9" as strings
        XCTAssertTrue(VersionManager.isVersionOlder("1.9.9", than: "1.10.0"))
        XCTAssertTrue(VersionManager.isVersionOlder("2.0.0", than: "10.0.0"))
        XCTAssertFalse(VersionManager.isVersionOlder("1.10.0", than: "1.9.9"))
    }

    func testDifferentComponentCounts() {
        // Missing components are treated as 0
        XCTAssertTrue(VersionManager.isVersionOlder("1.0", than: "1.0.1"))
        XCTAssertFalse(VersionManager.isVersionOlder("1.0.0", than: "1.0"))
        XCTAssertFalse(VersionManager.isVersionOlder("1", than: "1.0.0"))
        XCTAssertTrue(VersionManager.isVersionOlder("1", than: "1.0.1"))
    }

    func testMajorVersionBoundaries() {
        XCTAssertTrue(VersionManager.isVersionOlder("1.9.9", than: "2.0.0"))
        XCTAssertFalse(VersionManager.isVersionOlder("2.0.0", than: "1.9.9"))
    }

    /// Documents current behavior: non-numeric components are silently
    /// dropped by `compactMap { Int($0) }`, so "1.0.5-beta" becomes
    /// [1, 0] and compares as "1.0.0". If this ever changes to strict
    /// parsing, update this test together with `driverNeedsUpdate()`.
    func testNonNumericComponentsAreDropped() {
        XCTAssertTrue(VersionManager.isVersionOlder("1.0.5-beta", than: "1.0.5"))
        XCTAssertFalse(VersionManager.isVersionOlder("1.0.5", than: "1.0.5-beta"))
        // "1.0.x" -> [1, 0]: the dropped third component becomes 0, so it
        // counts as older than any real patch number.
        XCTAssertTrue(VersionManager.isVersionOlder("1.0.x", than: "1.0.1"))
        XCTAssertFalse(VersionManager.isVersionOlder("1.0.x", than: "1.0.0"))
    }

    // MARK: - areVersionsEqual

    func testAreVersionsEqual() {
        XCTAssertTrue(VersionManager.areVersionsEqual("1.0.5", "1.0.5"))
        // String equality only — no numeric normalization
        XCTAssertFalse(VersionManager.areVersionsEqual("1.0", "1.0.0"))
        XCTAssertFalse(VersionManager.areVersionsEqual("1.0.5", "1.0.5-beta"))
    }
}
