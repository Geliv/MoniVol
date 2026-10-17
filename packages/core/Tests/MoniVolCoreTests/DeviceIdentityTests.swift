import XCTest
@testable import MoniVolCore

/// Tests for physical device identity matching across display UID changes.
final class DeviceIdentityTests: XCTestCase {

    private let base = "3103FFFF-0000-0000-0120-0104B53C2278"

    // MARK: - baseUID

    func testStripsHexIndexSuffix() {
        XCTAssertEqual(DeviceIdentity.baseUID(base + "_00000000"), base)
        XCTAssertEqual(DeviceIdentity.baseUID(base + "_00ABCDEF"), base)
    }

    func testKeepsUIDWithoutSuffix() {
        XCTAssertEqual(DeviceIdentity.baseUID(base), base)
        XCTAssertEqual(DeviceIdentity.baseUID("BuiltInSpeakerDevice"), "BuiltInSpeakerDevice")
        XCTAssertEqual(DeviceIdentity.baseUID("AppleUSBAudio-5510:0"), "AppleUSBAudio-5510:0")
        XCTAssertEqual(DeviceIdentity.baseUID("abc-monivol"), "abc-monivol")
    }

    func testDoesNotStripNonHexSuffix() {
        XCTAssertEqual(DeviceIdentity.baseUID(base + "_0000000Z"),
                       base + "_0000000Z")
        XCTAssertEqual(DeviceIdentity.baseUID("_00000000"), "_00000000")
    }

    // MARK: - uniqueMatch

    func testMatchesChangedSuffix() {
        XCTAssertEqual(
            DeviceIdentity.uniqueMatch(
                for: base + "_00000000",
                among: [base, "BuiltInSpeakerDevice"]
            ),
            base
        )
    }

    func testReturnsNilWhenAmbiguous() {
        XCTAssertNil(
            DeviceIdentity.uniqueMatch(
                for: base,
                among: [base + "_00000000", base + "_00000001"]
            )
        )
    }

    func testReturnsNilWhenAbsent() {
        XCTAssertNil(
            DeviceIdentity.uniqueMatch(
                for: "Other-Device_00000000",
                among: [base, "BuiltInSpeakerDevice"]
            )
        )
    }
}
