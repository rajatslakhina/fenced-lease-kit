import Foundation

/// Observable counters describing what the coordinator actually did.
///
/// These exist because every interesting property of this system is invisible in
/// the happy path. A lease that is never stolen and a lease that is stolen every
/// thirty seconds behave identically from the caller's side -- right up to the
/// point where the second one is silently losing writes. `stealsFromExpiredLease`
/// and `fencedWriteRejections` are the two numbers that would have caught that,
/// so they are part of the public surface rather than a debug print.
public struct LeaseDiagnostics: Sendable, Equatable {

    /// Leases granted on a key that had no live holder.
    public var acquisitions: Int = 0

    /// Deadline extensions that kept the same epoch.
    public var renewals: Int = 0

    /// Leases taken over from a holder whose deadline had passed.
    ///
    /// Includes taking over from a *previous epoch of this same process*, which
    /// is the case that catches a suspended-past-expiry holder.
    public var stealsFromExpiredLease: Int = 0

    /// Voluntary releases. Each leaves a tombstone, not a deletion.
    public var releases: Int = 0

    /// Acquisitions refused because a live holder existed.
    public var contentionRejections: Int = 0

    /// Entries refused because the store's critical section was unavailable
    /// within budget. Distinct from ``contentionRejections``.
    public var storeBusyRejections: Int = 0

    /// Writes refused for presenting a superseded epoch.
    ///
    /// The headline number. A non-zero value is not an error -- it means the
    /// fence did its job and a stale writer was stopped. A value that grows
    /// steadily means leases are too short for the work they guard.
    public var fencedWriteRejections: Int = 0

    /// Single-flight calls that reused a peer's result instead of recomputing.
    public var singleFlightReuses: Int = 0

    /// Single-flight calls that performed the computation.
    public var singleFlightComputations: Int = 0

    public init() {}
}

/// Thread-safe accumulator for ``LeaseDiagnostics``.
///
/// Counters saturate rather than overflow -- see ``Saturating``. A telemetry
/// counter is never a control value here, so clamping at `Int.max` loses
/// information in a scenario that cannot occur, while trapping would take down
/// the app in the same scenario.
public final class DiagnosticsRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var counters = LeaseDiagnostics()

    public init() {}

    public var current: LeaseDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    func record(_ mutate: (inout LeaseDiagnostics) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        mutate(&counters)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        counters = LeaseDiagnostics()
    }
}
