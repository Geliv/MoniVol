import XCTest
@testable import MoniVolCore

/// Tests for the proxy UID / display name rules.
///
/// The driver (C++, `packages/driver/src/Plugin.cpp`) hardcodes the same
/// suffix literals — see AGENTS.md. These tests pin the Swift-side values so
/// an accidental change fails `make test` instead of silently breaking the
/// driver/Host naming handshake.
final class ProxyNamingTests: XCTestCase {

    // MARK: - Pinned literals (must match Plugin.cpp)

    func testPinnedLiterals() {
        XCTAssertEqual(ProxyNaming.uidSuffix, "-monivol")
        XCTAssertEqual(ProxyNaming.nameMarker, "MoniVol")
        XCTAssertEqual(ProxyNaming.nameSuffix, " (MoniVol)")
    }

    // MARK: - UID round trip

    func testProxyUIDAppendsSuffix() {
        XCTAssertEqual(
            ProxyNaming.proxyUID(for: "DisplayPort-0x1234"),
            "DisplayPort-0x1234-monivol"
        )
    }

    func testUIDRoundTrip() {
        let physical = "AppleUSBAudio-5510:0"
        let proxy = ProxyNaming.proxyUID(for: physical)
        XCTAssertTrue(ProxyNaming.isProxyUID(proxy))
        XCTAssertEqual(ProxyNaming.physicalUID(from: proxy), physical)
    }

    // MARK: - isProxyUID

    func testIsProxyUID() {
        XCTAssertTrue(ProxyNaming.isProxyUID("abc-monivol"))
        XCTAssertTrue(ProxyNaming.isProxyUID("-monivol")) // suffix only
        XCTAssertFalse(ProxyNaming.isProxyUID("abc"))
        XCTAssertFalse(ProxyNaming.isProxyUID("abc-monivol-extra"))
        XCTAssertFalse(ProxyNaming.isProxyUID("abc-MoniVol")) // case sensitive
        XCTAssertFalse(ProxyNaming.isProxyUID(""))
    }

    // MARK: - physicalUID(from:)

    func testPhysicalUIDFromNonProxyReturnsNil() {
        XCTAssertNil(ProxyNaming.physicalUID(from: "abc"))
        XCTAssertNil(ProxyNaming.physicalUID(from: "abc-moniv"))
        XCTAssertNil(ProxyNaming.physicalUID(from: ""))
    }

    // MARK: - Edge cases

    func testUIDAlreadySuffixed() {
        // A physical UID that itself ends in "-monivol" still round-trips,
        // because the proxy simply appends the suffix again.
        let physical = "weird-monivol"
        let proxy = ProxyNaming.proxyUID(for: physical)
        XCTAssertEqual(proxy, "weird-monivol-monivol")
        XCTAssertEqual(ProxyNaming.physicalUID(from: proxy), physical)
        // Note: the intermediate value is itself classified as a proxy UID.
        XCTAssertTrue(ProxyNaming.isProxyUID(physical))
    }

    func testNameSuffixRoundTrip() {
        let physicalName = "DELL U2723QE"
        let proxyName = physicalName + ProxyNaming.nameSuffix
        XCTAssertEqual(proxyName, "DELL U2723QE (MoniVol)")
        XCTAssertEqual(proxyName.replacingOccurrences(of: ProxyNaming.nameSuffix, with: ""),
                       physicalName)
    }
}
