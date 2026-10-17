/// Identity rules for physical audio devices.
///
/// DisplayPort/HDMI audio devices can report a UID with a trailing
/// `_XXXXXXXX` index that changes across boots or reconnects, while the
/// EDID-derived prefix stays the same. Preferences and persisted state that
/// outlive one boot must tolerate that change.
///
/// Two identical displays can share the same prefix and differ only in the
/// index, so a prefix match is only safe when it identifies one device.
public enum DeviceIdentity {

    /// Strips a trailing `_XXXXXXXX` index from a physical device UID.
    /// Returns the UID unchanged when it has no such suffix.
    public static func baseUID(_ uid: String) -> String {
        guard uid.count > 9 else { return uid }
        let separator = uid[uid.index(uid.endIndex, offsetBy: -9)]
        guard separator == "_",
              uid.suffix(8).allSatisfy({ $0.isHexDigit }) else {
            return uid
        }
        return String(uid.dropLast(9))
    }

    /// Returns the only candidate whose base UID matches `uid`, or nil when
    /// there is no match or the match is ambiguous.
    public static func uniqueMatch(for uid: String, among candidates: [String]) -> String? {
        let base = baseUID(uid)
        var match: String?
        for candidate in candidates where baseUID(candidate) == base {
            if match != nil { return nil }
            match = candidate
        }
        return match
    }
}
