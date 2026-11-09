#if os(iOS) && canImport(ManagedSettings)
import Foundation
import os

/// Loggers shared by TetherKit. Never log tokens, PINs or app identities.
enum TLog {
    static let reconcile = Logger(subsystem: "tether", category: "reconcile")
    static let shield = Logger(subsystem: "tether", category: "shield")
    static let schedule = Logger(subsystem: "tether", category: "schedule")
    static let auth = Logger(subsystem: "tether", category: "auth")
    static let protection = Logger(subsystem: "tether", category: "protection")
    static let sync = Logger(subsystem: "tether", category: "sync")
    static let keychain = Logger(subsystem: "tether", category: "keychain")
}
#endif
