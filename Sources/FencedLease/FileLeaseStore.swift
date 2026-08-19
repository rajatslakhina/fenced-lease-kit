import Foundation

/// A ``LeaseStore`` that coordinates real, separate processes through a shared
/// directory -- on iOS, the App Group container returned by
/// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`.
///
/// The atomicity comes entirely from ``FileMutex``; this type is the record
/// serialisation on top of it. See ``FileMutex`` for why `flock` rather than
/// `NSFileCoordinator`, and why the lock file is never the record file.
public struct FileLeaseStore: LeaseStore {

    /// Directory holding the lock and record files.
    public let directory: URL

    /// Forwarded to each key's ``FileMutex``.
    public let acquisitionBudget: TimeInterval

    private let clock: any LeaseClock

    public init(
        directory: URL,
        acquisitionBudget: TimeInterval = 0.25,
        clock: any LeaseClock = SystemLeaseClock()
    ) throws {
        self.directory = directory
        self.acquisitionBudget = acquisitionBudget
        self.clock = clock

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw LeaseError.storageFailure("could not create \(directory.path): \(error)")
        }
    }

    // MARK: - LeaseStore

    public func withExclusiveAccess<T>(
        to key: LeaseKey,
        _ body: (LeaseRecord?) throws -> (LeaseMutation, T)
    ) throws -> T {
        // One mutex per key, so unrelated resources never serialise against each
        // other. `LeaseKey` has already rejected path separators and all-dot
        // values, which is what makes it safe to interpolate into a filename.
        let mutex = FileMutex(
            directory: directory,
            regionName: "\(key.rawValue).lease",
            budget: acquisitionBudget,
            clock: clock
        )

        return try mutex.withExclusiveAccess {
            let current = try readRecord(for: key)
            let (mutation, result) = try body(current)

            switch mutation {
            case .leave:
                break
            case let .store(record):
                let data = try Self.encode(record)
                try AtomicFile.write(data, to: recordURL(for: key))
            case .remove:
                try AtomicFile.remove(recordURL(for: key))
            }
            return result
        }
    }

    // MARK: - Record IO

    private func readRecord(for key: LeaseKey) throws -> LeaseRecord? {
        guard let data = try AtomicFile.read(recordURL(for: key)) else { return nil }
        // A record that fails to decode is treated as absent rather than fatal.
        // Refusing to proceed would turn a one-off corrupt file into a permanent
        // outage on that key.
        //
        // This is safe *only because the epoch sequence has a second memory.* On its
        // own, discarding the record would restart the sequence at 1 while the
        // resource still holds a higher mark -- a real safety hole, since a
        // resurrected holder from an earlier epoch would then compare equal to a
        // fresh one. ``EpochFloorProvider`` is what closes it: the coordinator issues
        // the next epoch above both this record and the resource's high-water mark,
        // so a lost record costs mutual exclusion for one epoch rather than
        // correctness of the data.
        //
        // The residual case, stated plainly: record lost *and* the resource never
        // written. Nothing remembers, and the sequence does restart at 1. Narrow, but
        // real -- see ``EpochFloorProvider``.
        return try? Self.decode(data)
    }

    private func recordURL(for key: LeaseKey) -> URL {
        directory.appendingPathComponent("\(key.rawValue).lease.json")
    }

    // MARK: - Coding

    private static func encode(_ record: LeaseRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(record)
        } catch {
            throw LeaseError.storageFailure("encode record: \(error)")
        }
    }

    private static func decode(_ data: Data) throws -> LeaseRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LeaseRecord.self, from: data)
    }
}
