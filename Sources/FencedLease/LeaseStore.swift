import Foundation

// MARK: - LeaseMutation

/// What a store should do with a record after the caller has inspected it.
public enum LeaseMutation: Sendable, Equatable {
    /// Persist nothing. Used for read-only inspection and for rejected
    /// acquisitions, so a failed `acquire` never writes.
    case leave
    /// Replace the record.
    case store(LeaseRecord)
    /// Delete the record, making the key immediately available.
    case remove
}

// MARK: - LeaseStore

/// The durable rendezvous point between processes.
///
/// There is exactly one operation, and its atomicity is the entire contract:
/// ``withExclusiveAccess(to:_:)`` must run `body` such that no other process --
/// not merely no other thread -- can observe or modify the record for `key`
/// between the read `body` receives and the write it returns.
///
/// Two mechanisms with two different jobs, which is worth being explicit about
/// because collapsing them is the usual mistake:
///
/// - **This protocol** provides a short, strictly-scoped critical section. It is
///   held for microseconds and it is released by the OS if the holder dies.
///   Its job is to make the lease bookkeeping's read-modify-write atomic.
/// - **The lease** provides long-lived, crash-tolerant mutual exclusion over the
///   actual resource. Its job is to survive the holder's death, which an OS lock
///   cannot do, because the OS lock's automatic release is exactly what makes it
///   unusable for a claim that should outlive a `SIGKILL`.
///
/// Using an OS lock for the second job deadlocks the moment a holder is
/// jetsammed. Using a lease for the first job has no atomic primitive to build
/// on. Hence both.
public protocol LeaseStore: Sendable {

    /// Atomically inspect and conditionally replace the record for `key`.
    ///
    /// - Parameter body: Receives the current record, or `nil` if none exists.
    ///   Returns the mutation to apply and a value to hand back to the caller.
    ///   `body` must not itself call back into the store: it runs inside the
    ///   critical section and doing so would self-deadlock.
    /// - Throws: ``LeaseError/storeBusy(region:)`` if exclusivity could not be
    ///   obtained within the store's own budget, or ``LeaseError/storageFailure(_:)``.
    func withExclusiveAccess<T>(
        to key: LeaseKey,
        _ body: (LeaseRecord?) throws -> (LeaseMutation, T)
    ) throws -> T
}

// MARK: - InMemoryLeaseStore

/// A ``LeaseStore`` backed by a dictionary behind a mutex.
///
/// Correct for coordinating threads inside one process, and used by the test suite so
/// that lease *logic* can be exercised without touching a filesystem. It cannot
/// coordinate across processes -- that is ``FileLeaseStore``'s job -- and the two are
/// tested against the same shared conformance suite so the in-memory fake cannot
/// drift into being more forgiving than the real thing. That includes rejecting
/// re-entry: a recursive lock alone would let a nested call succeed here and fail
/// against the file store.
public final class InMemoryLeaseStore: LeaseStore, @unchecked Sendable {

    private let lock = NSRecursiveLock()
    private var records: [LeaseKey: LeaseRecord] = [:]

    /// Set to make the next `n` entries fail with ``LeaseError/storeBusy(region:)``,
    /// so callers' contention handling is reachable in tests.
    private var forcedBusyCount = 0

    /// Non-zero while a body is running. A *different* thread blocks on the lock and
    /// never observes it set; only a re-entering thread gets past and sees the guard.
    private var depth = 0

    public init() {}

    public func withExclusiveAccess<T>(
        to key: LeaseKey,
        _ body: (LeaseRecord?) throws -> (LeaseMutation, T)
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        guard depth == 0 else {
            throw LeaseError.storeBusy(region: "\(key.rawValue) (re-entered)")
        }
        depth += 1
        defer { depth -= 1 }

        if forcedBusyCount > 0 {
            forcedBusyCount -= 1
            throw LeaseError.storeBusy(region: key.rawValue)
        }

        let (mutation, result) = try body(records[key])
        switch mutation {
        case .leave:
            break
        case let .store(record):
            records[key] = record
        case .remove:
            records[key] = nil
        }
        return result
    }

    /// Force the next `count` calls to report contention.
    public func simulateBusy(forNextCalls count: Int) {
        lock.lock()
        defer { lock.unlock() }
        forcedBusyCount = max(0, count)
    }

    /// Snapshot of every record, for assertions.
    public var snapshot: [LeaseKey: LeaseRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}
