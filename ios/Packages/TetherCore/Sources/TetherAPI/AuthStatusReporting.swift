import Foundation

/// Which Screen Time authorization status an ack reports (`AckRequest.authorizationStatus`).
/// Pure so it is testable off-device; TetherKit supplies the live reading.
///
/// A `.notDetermined` read is often a launch-time blip, and in extensions (the push NSE syncs from a
/// background launch) it isn't a reliable reading at all; acking it made the dashboard flash
/// "revoked" (M1 F2). So, when the app previously recorded a definite status:
/// - extensions report that recorded status (the app owns authorization and records real changes);
/// - the app re-reads up to `attempts` times, then reports what it sees, so a lasting revocation
///   that reads `.notDetermined` still reaches the server.
/// Definite reads (`.approved`, `.denied`) are reported immediately.
public enum AuthStatusReporting {
    public static func resolve(read: () -> AuthorizationStatusValue,
                               lastRecorded: AuthorizationStatusValue?,
                               isExtension: Bool,
                               attempts: Int = 6,
                               wait: () async -> Void) async -> AuthorizationStatusValue {
        var v = read()
        guard v == .notDetermined, let last = lastRecorded, last != .notDetermined else { return v }
        if isExtension { return last }
        for _ in 0..<attempts {
            await wait()
            v = read()
            if v != .notDetermined { break }
        }
        return v
    }
}
