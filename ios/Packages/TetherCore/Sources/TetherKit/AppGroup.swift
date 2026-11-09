#if os(iOS) && canImport(ManagedSettings)
import Foundation

/// App Group / Keychain group / server defaults. Values come from the Info.plist of the
/// *current* bundle (app or extension; W7 puts the same three keys into every target).
public enum AppGroup {
    public static let fallbackIdentifier = "group.com.newwestsite.tether"

    private static func plistString(_ key: String) -> String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unexpanded build setting ("$(BUNDLE_ID_PREFIX)…") or empty -> treat as missing.
        if t.isEmpty || t.contains("$(") { return nil }
        return t
    }

    /// Info.plist `TetherAppGroup`, fallback `group.com.newwestsite.tether`.
    public static let identifier: String = plistString("TetherAppGroup") ?? fallbackIdentifier

    /// Info.plist `TetherKeychainGroup` (already includes the team-ID prefix), or nil.
    public static let keychainGroup: String? = plistString("TetherKeychainGroup")

    /// Info.plist `TetherDefaultServerURL`, or nil when unset / unparsable.
    public static var defaultServerURL: URL? {
        guard let s = plistString("TetherDefaultServerURL") else { return nil }
        return URL(string: s)
    }

    /// The shared container directory. If the App Group is not provisioned (Simulator
    /// without entitlements, unit tests) falls back to a private directory so the code
    /// keeps working — but then the extensions will NOT see the same data.
    public static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TetherFallbackGroup", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// True when the real App Group container is available.
    public static var isProvisioned: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil
    }

    /// UserDefaults in the App Group (small flags only).
    public static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}
#endif
