/// Naming rules for MoniVol proxy devices.
///
/// The HAL driver (C++, `packages/driver/src/Plugin.cpp`) creates proxy
/// devices using these same rules; the literals there must be kept in sync
/// with this file until the driver can share Swift code.
public enum ProxyNaming {

    /// Suffix appended to the physical device UID to form the proxy UID.
    /// Driver side: `params.DeviceUID = uid + "-monivol"`.
    public static let uidSuffix = "-monivol"

    /// Marker used to recognise MoniVol devices by display name.
    public static let nameMarker = "MoniVol"

    /// Suffix stripped from the proxy display name to recover the physical
    /// device name, e.g. "DELL U2723QE (MoniVol)".
    public static let nameSuffix = " (MoniVol)"

    /// Physical UID -> proxy UID.
    public static func proxyUID(for physicalUID: String) -> String {
        return physicalUID + uidSuffix
    }

    /// Whether a UID belongs to a MoniVol proxy device.
    public static func isProxyUID(_ uid: String) -> Bool {
        return uid.hasSuffix(uidSuffix)
    }

    /// Proxy UID -> physical UID. Returns nil for non-proxy UIDs.
    public static func physicalUID(from uid: String) -> String? {
        guard isProxyUID(uid) else { return nil }
        return String(uid.dropLast(uidSuffix.count))
    }
}
