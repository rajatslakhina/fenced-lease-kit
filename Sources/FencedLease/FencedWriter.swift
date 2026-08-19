import Foundation

// MARK: - FencedEnvelope

/// A stored value together with the epoch that wrote it.
///
/// The `acceptedToken` *is* the high-water mark. Keeping it next to the payload,
/// rather than in the lease record, is the point: a lease record can be lost
/// (deleted, corrupted, cleared by the OS reclaiming the container) without
/// weakening the fence, because the resource itself remembers the newest epoch
/// that ever touched it.
public struct FencedEnvelope: Codable, Sendable, Equatable {

    /// The highest epoch that has successfully written this resource.
    public let acceptedToken: FencingToken
    public let payload: Data
    public let writtenAt: Date
    /// ``ProcessIdentity/label`` of the writer, for diagnostics only.
    public let writerLabel: String

    public init(
        acceptedToken: FencingToken,
        payload: Data,
        writtenAt: Date,
        writerLabel: String
    ) {
        self.acceptedToken = acceptedToken
        self.payload = payload
        self.writtenAt = writtenAt
        self.writerLabel = writerLabel
    }
}

// MARK: - FencedStorage

/// Durable storage for **one** fenced resource.
///
/// The single operation is atomic for the same reason ``LeaseStore``'s is: the fence is
/// a read-compare-write, and a fence checked non-atomically is not a fence. Two writers
/// that both read the same high-water mark would both pass the comparison, and the
/// stale one could land second.
///
/// ## One storage per key
///
/// A `FencedStorage` holds a single envelope and therefore a single high-water mark, so
/// it must be bound 1:1 to a ``LeaseKey``. Sharing one instance across two keys makes
/// them fence *each other*: `beta` reaching epoch 5 leaves a live holder of `alpha` at
/// epoch 3 permanently rejected, because the mark is global to the storage and the
/// epochs are per key. ``FileFencedStorage`` takes a `resourceName` and derives its
/// filename from it for exactly this reason -- one file per key.
public protocol FencedStorage: Sendable {

    /// Atomically inspect the current envelope and conditionally replace it.
    ///
    /// - Parameter body: Receives the current envelope, or `nil` if the resource
    ///   has never been written. Returns the replacement envelope -- or `nil` to
    ///   write nothing -- and a value for the caller.
    func withExclusiveAccess<T>(
        _ body: (FencedEnvelope?) throws -> (FencedEnvelope?, T)
    ) throws -> T
}

// MARK: - InMemoryFencedStorage

/// A ``FencedStorage`` behind a mutex, for tests and for single-process use.
///
/// Rejects re-entry from the same thread, matching ``FileFencedStorage``. A
/// recursive lock here would let a nested call succeed in the fake and fail in the
/// real store -- the fake being *more forgiving* than the thing it stands in for,
/// which is the failure mode a shared conformance suite exists to prevent.
public final class InMemoryFencedStorage: FencedStorage, @unchecked Sendable {

    private let lock = NSRecursiveLock()
    private var envelope: FencedEnvelope?
    /// Non-zero while a body is running. Read under `lock`, so a *different* thread
    /// blocks on the lock and never observes it set; only the re-entering thread
    /// gets past the lock and sees the guard.
    private var depth = 0

    public init(seed: FencedEnvelope? = nil) {
        self.envelope = seed
    }

    public func withExclusiveAccess<T>(
        _ body: (FencedEnvelope?) throws -> (FencedEnvelope?, T)
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard depth == 0 else {
            throw LeaseError.storeBusy(region: "in-memory-fenced-storage (re-entered)")
        }
        depth += 1
        defer { depth -= 1 }

        let (replacement, result) = try body(envelope)
        if let replacement {
            envelope = replacement
        }
        return result
    }

    public var snapshot: FencedEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return envelope
    }
}

// MARK: - FileFencedStorage

/// A ``FencedStorage`` in a shared directory, safe across processes.
public struct FileFencedStorage: FencedStorage {

    private let envelopeURL: URL
    private let mutex: FileMutex

    /// - Parameters:
    ///   - directory: Must be writable; created if absent.
    ///   - resourceName: Basename for the envelope and lock files. Validated as a
    ///     ``LeaseKey`` so it cannot contain a path separator.
    public init(
        directory: URL,
        resourceName: LeaseKey,
        budget: TimeInterval = 0.25,
        clock: any LeaseClock = SystemLeaseClock()
    ) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw LeaseError.storageFailure("could not create \(directory.path): \(error)")
        }
        self.envelopeURL = directory
            .appendingPathComponent("\(resourceName.rawValue).fenced.json")
        self.mutex = FileMutex(
            directory: directory,
            regionName: "\(resourceName.rawValue).fenced",
            budget: budget,
            clock: clock
        )
    }

    public func withExclusiveAccess<T>(
        _ body: (FencedEnvelope?) throws -> (FencedEnvelope?, T)
    ) throws -> T {
        try mutex.withExclusiveAccess {
            let current: FencedEnvelope?
            if let data = try AtomicFile.read(envelopeURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                // Unlike a lease record, a *corrupt envelope must not be treated
                // as absent*: doing so would reset the high-water mark to nothing
                // and re-admit every superseded writer. Failing loudly is the only
                // safe reading, so the resource stays locked out until a human or
                // a recovery path decides what the newest epoch was.
                do {
                    current = try decoder.decode(FencedEnvelope.self, from: data)
                } catch {
                    throw LeaseError.storageFailure(
                        "fenced envelope at \(envelopeURL.lastPathComponent) is unreadable "
                        + "and cannot be safely ignored: \(error)"
                    )
                }
            } else {
                current = nil
            }

            let (replacement, result) = try body(current)
            if let replacement {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                let data: Data
                do {
                    data = try encoder.encode(replacement)
                } catch {
                    throw LeaseError.storageFailure("encode envelope: \(error)")
                }
                try AtomicFile.write(data, to: envelopeURL)
            }
            return result
        }
    }
}

// MARK: - FencedWriter

/// The write path. Rejects any write whose epoch has been superseded.
///
/// ## The rule, and why it is `<` and not `<=`
///
/// A write is rejected exactly when `presented < highWaterMark`. Equality is
/// accepted, because a holder legitimately writes many times within one epoch and
/// rejecting its second write would make the lease useless.
///
/// That single comparison is the whole safety property, and it is worth spelling
/// out why it is *sufficient* -- the deadline plays no part:
///
/// - If nobody has taken over, the high-water mark equals this holder's token, so
///   the write is accepted. Correct: no peer has written, so there is nothing to
///   clobber. Notably this holds **even if the lease has expired**, which is why
///   the writer does not consult the deadline at all.
/// - If somebody has taken over, ``LeaseCoordinator`` incremented the token when
///   granting the new epoch, so the stale holder's token is strictly lower and the
///   write is rejected. Correct: a peer owns the resource now.
///
/// So the fence is precisely as strict as it needs to be and no stricter, and it
/// needs no trustworthy clock to be right. Everything the wall clock is bad at --
/// jumping, skewing, being stopped -- costs liveness (a lease stolen sooner or
/// later than intended) and never safety.
public final class FencedWriter<Value: Codable & Sendable>: Sendable {

    private let storage: any FencedStorage
    private let clock: any LeaseClock
    private let recorder: DiagnosticsRecorder

    public init(
        storage: any FencedStorage,
        clock: any LeaseClock = SystemLeaseClock(),
        recorder: DiagnosticsRecorder = DiagnosticsRecorder()
    ) {
        self.storage = storage
        self.clock = clock
        self.recorder = recorder
    }

    public var diagnostics: LeaseDiagnostics { recorder.current }

    /// Writes `value`, but only if `lease`'s epoch has not been superseded.
    ///
    /// - Throws: ``LeaseError/fenced(presented:highWaterMark:)`` if a later epoch
    ///   has already written. Nothing is persisted in that case.
    public func write(_ value: Value, using lease: Lease) throws {
        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoded = try encoder.encode(value)
        } catch {
            throw LeaseError.storageFailure("encode value: \(error)")
        }

        // Encoding happens *outside* the critical section on purpose: it can be
        // arbitrarily slow for a large value, and holding a cross-process mutex
        // across it would let one writer's serialisation cost stall every peer.
        try storage.withExclusiveAccess { current in
            if let current, lease.token < current.acceptedToken {
                recorder.record {
                    $0.fencedWriteRejections = Saturating.increment($0.fencedWriteRejections)
                }
                throw LeaseError.fenced(
                    presented: lease.token,
                    highWaterMark: current.acceptedToken
                )
            }
            let envelope = FencedEnvelope(
                acceptedToken: lease.token,
                payload: encoded,
                writtenAt: clock.wallTime,
                writerLabel: lease.holder.label
            )
            return (envelope, ())
        }
    }

    /// The current value, or `nil` if never written.
    public func read() throws -> Value? {
        try storage.withExclusiveAccess { current in
            guard let current else { return (nil, nil) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let value = try decoder.decode(Value.self, from: current.payload)
            return (nil, value)
        }
    }

    /// The current value together with its epoch and provenance.
    public func readEnvelope() throws -> (value: Value, envelope: FencedEnvelope)? {
        try storage.withExclusiveAccess { current in
            guard let current else { return (nil, nil) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let value = try decoder.decode(Value.self, from: current.payload)
            return (nil, (value, current))
        }
    }

    /// The highest epoch that has written this resource, or `nil` if untouched.
    public func highWaterMark() throws -> FencingToken? {
        try storage.withExclusiveAccess { current in
            (nil, current?.acceptedToken)
        }
    }
}

// MARK: - EpochFloorProvider

extension FencedWriter: EpochFloorProvider {

    /// The resource's own memory of the epoch sequence.
    ///
    /// Pass the writer to ``LeaseCoordinator/init(store:identity:clock:recorder:epochFloor:selfReacquisition:)``
    /// so a new epoch is issued above this mark as well as above the lease record.
    /// That is what keeps the sequence monotonic when the lease record is lost, which
    /// the record alone cannot do.
    public func epochFloor() throws -> FencingToken? {
        try highWaterMark()
    }
}
