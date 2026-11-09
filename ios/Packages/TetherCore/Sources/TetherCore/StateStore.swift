// StateStore.swift — atomic JSON persistence of `PersistedState` (App Group `state.json`).
//
// - `load()` of a missing file yields a fresh `PersistedState`.
// - `update(_:)` is a locked read-modify-write; the write is atomic (temp file + rename).
// - On Apple platforms every access goes through `NSFileCoordinator`, which serialises the
//   app and its extensions (separate processes) on the same file. A process-local lock
//   serialises threads inside one process (NSFileCoordinator is not re-entrant per thread).
// - We deliberately do NOT use flock/POSIX locks on the shared container: iOS kills
//   suspended processes holding file locks in an App Group (0xdead10cc).

import Foundation

public final class StateStore: @unchecked Sendable {
    public static let fileName = "state.json"

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// When true (default) `update(_:)` prunes old data (see `PersistedState.prune`) before writing.
    public var pruneOnUpdate: Bool
    private let clock: @Sendable () -> Date

    /// One lock for all instances in the process: different `StateStore` objects may point at the same file.
    private static let processLock = NSLock()

    public init(directory: URL, pruneOnUpdate: Bool = true, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.pruneOnUpdate = pruneOnUpdate
        self.clock = clock
    }

    // MARK: Read

    /// Reads the state. A missing file returns `PersistedState()`; an unreadable/corrupt file throws.
    public func load() throws -> PersistedState {
        Self.processLock.lock(); defer { Self.processLock.unlock() }
        return try coordinated(writing: false) { try self.readLocked() ?? PersistedState() }
    }

    // MARK: Read-modify-write

    /// Loads, applies `body`, prunes (if enabled), atomically writes, and returns the new state.
    /// If `body` throws nothing is written. A corrupt file is moved aside to `state.corrupt.json`
    /// and replaced by a fresh state (the server re-supplies the bundle on next sync).
    @discardableResult
    public func update(_ body: (inout PersistedState) throws -> Void) throws -> PersistedState {
        Self.processLock.lock(); defer { Self.processLock.unlock() }
        return try coordinated(writing: true) {
            var state: PersistedState
            do {
                state = try self.readLocked() ?? PersistedState()
            } catch is DecodingError {
                let aside = self.directory.appendingPathComponent("state.corrupt.json")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: self.fileURL, to: aside)
                state = PersistedState()
            }
            try body(&state)
            if self.pruneOnUpdate { state.prune(now: self.clock()) }
            try self.writeLocked(state)
            return state
        }
    }

    // MARK: Internals

    private func readLocked() throws -> PersistedState? {
        guard let data = try? Data(contentsOf: fileURL) else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                throw CocoaError(.fileReadUnknown)
            }
            return nil
        }
        if data.isEmpty { return nil }
        return try TetherJSON.makeDecoder().decode(PersistedState.self, from: data)
    }

    private func writeLocked(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try TetherJSON.makeEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)   // temp file in the same directory + rename
    }

    private func coordinated<T>(writing: Bool, _ work: () throws -> T) throws -> T {
        #if canImport(Darwin)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let accessor: (URL) -> Void = { _ in result = Result { try work() } }
        if writing {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            coordinator.coordinate(writingItemAt: fileURL, options: [], error: &coordinationError, byAccessor: accessor)
        } else {
            coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinationError, byAccessor: accessor)
        }
        if let e = coordinationError { throw e }
        guard let r = result else { throw CocoaError(.fileReadUnknown) }
        return try r.get()
        #else
        return try work()
        #endif
    }
}

// MARK: - Pruning

extension PersistedState {
    public static let sessionRetention: TimeInterval = 7 * 86400
    public static let pauseRetention: TimeInterval = 7 * 86400
    public static let usageHitRetentionDays = 2
    public static let maxPendingEvents = 500

    /// Drops sessions/pauses that ended more than 7 days ago, usage-limit hits older than
    /// 2 days, and caps `pendingEvents` at 500 (oldest dropped first).
    public mutating func prune(now: Date, timeZone: TimeZone? = nil) {
        let sessionCutoff = now.addingTimeInterval(-Self.sessionRetention)
        sessions.removeAll { s in
            let ended = min(s.endsAt, s.endedAt ?? s.endsAt)
            return ended < sessionCutoff
        }
        let pauseCutoff = now.addingTimeInterval(-Self.pauseRetention)
        pauses.removeAll { $0.endsAt < pauseCutoff }

        let tz = timeZone ?? bundle?.timeZone.flatMap { TimeZone(identifier: $0) } ?? TimeZone.current
        let hitCutoff = ScheduleMath.dayString(now.addingTimeInterval(-Double(Self.usageHitRetentionDays) * 86400), in: tz)
        usageLimitHits.removeAll { $0.day < hitCutoff }

        if pendingEvents.count > Self.maxPendingEvents {
            pendingEvents.removeFirst(pendingEvents.count - Self.maxPendingEvents)
        }
    }

    public func pruned(now: Date, timeZone: TimeZone? = nil) -> PersistedState {
        var copy = self
        copy.prune(now: now, timeZone: timeZone)
        return copy
    }
}
