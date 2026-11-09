import Foundation
import TetherCore

/// Minimal persistence surface SyncEngine needs. `TetherCore.StateStore` conforms
/// (see StateStore+StateStoring.swift); tests use an in-memory fake.
public protocol StateStoring: Sendable {
    func load() throws -> PersistedState
    @discardableResult
    func update(_ body: (inout PersistedState) throws -> Void) throws -> PersistedState
}
