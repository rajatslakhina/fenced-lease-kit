import Foundation

// MARK: - SelfReacquisitionPolicy

/// Decides whether a caller that finds its **own** identity on an expired record may
/// keep its existing epoch.
///
/// This is a seam, and it exists for one reason: the wrong answer here is extremely
/// tempting, and a test suite that only ever exercises the right answer cannot prove
/// the right answer matters. ``StrictSelfReacquisition`` is the only conformance that
/// ships; the test target injects a deliberately wrong one into the real coordinator
/// and asserts that real data loss follows.
public protocol SelfReacquisitionPolicy: Sendable {

    /// - Parameter expired: Whether the caller's own record has lapsed.
    /// - Returns: `true` to keep the existing epoch, `false` to issue a new one.
    func mayKeepEpoch(expired: Bool) -> Bool
}

/// The correct policy: keep the epoch only while the lease is genuinely live.
///
/// When a process finds its own name on an *expired* record, the tempting reading is
/// "still mine". It is not. The process cannot distinguish "nobody took over" from "a
/// peer took over, did its work, and released" -- both leave a record that either
/// says someone else's name or, after a tombstoned release, says available. Keeping
/// the epoch means resuming with a token the resource may already have moved past,
/// which is exactly the write the fence is supposed to reject.
public struct StrictSelfReacquisition: SelfReacquisitionPolicy {

    public init() {}

    public func mayKeepEpoch(expired: Bool) -> Bool { !expired }
}

// MARK: - LeaseCoordinator

/// Grants, renews and releases leases over keys in a shared container.
///
/// ## The invariant
///
/// **Every epoch issued for a key is strictly greater than every epoch previously
/// issued for that key.** Everything else in this package rests on it: the fence
/// compares epochs, so an epoch sequence that can go backwards makes the fence worse
/// than useless -- it starts rejecting legitimate writers and accepting stale ones.
///
/// Two things are needed to hold it, and each covers a case the other cannot:
///
/// - A release leaves a **tombstone** rather than deleting the record, so the epoch
///   survives an orderly handover with no writes in between.
/// - An optional ``EpochFloorProvider`` lets the coordinator also ask the guarded
///   resource how far it has seen, so the epoch survives *losing* the record.
///
/// ## Why this is not an actor
///
/// Every operation is a single, short, synchronous read-modify-write inside
/// ``LeaseStore/withExclusiveAccess(to:_:)``. There is no `await` in the critical
/// path, so there is no suspension point at which another task could re-enter and
/// observe half-applied state -- the class of bug that makes actor-based lock
/// managers subtly wrong. Mutual exclusion comes from the store; the only local
/// mutable state is the diagnostics counter, which has its own lock.
///
/// The cost of that choice, named rather than buried: `acquire` briefly **blocks its
/// calling thread**, bounded by the store's own budget (see
/// ``FileMutex/init(directory:regionName:budget:clock:)``). Callers on Swift
/// Concurrency's cooperative pool should be aware they are occupying a pool thread
/// for that window.
public final class LeaseCoordinator: Sendable {

    private let store: any LeaseStore
    private let clock: any LeaseClock
    private let identity: ProcessIdentity
    private let recorder: DiagnosticsRecorder
    private let epochFloor: (any EpochFloorProvider)?
    private let selfReacquisition: any SelfReacquisitionPolicy

    /// - Parameters:
    ///   - epochFloor: A second memory of the epoch sequence, normally the
    ///     ``FencedWriter`` guarding the same key. Strongly recommended: without it,
    ///     losing the lease record restarts the sequence at 1 while the resource
    ///     remembers a higher mark. Optional only because a caller may be using
    ///     leases for pure mutual exclusion with no fenced resource behind them.
    ///   - selfReacquisition: Leave at the default. Injected only by tests, to prove
    ///     the default is load-bearing.
    public init(
        store: any LeaseStore,
        identity: ProcessIdentity,
        clock: any LeaseClock = SystemLeaseClock(),
        recorder: DiagnosticsRecorder = DiagnosticsRecorder(),
        epochFloor: (any EpochFloorProvider)? = nil,
        selfReacquisition: any SelfReacquisitionPolicy = StrictSelfReacquisition()
    ) {
        self.store = store
        self.clock = clock
        self.identity = identity
        self.recorder = recorder
        self.epochFloor = epochFloor
        self.selfReacquisition = selfReacquisition
    }

    /// Counters describing this coordinator's history. See ``LeaseDiagnostics``.
    public var diagnostics: LeaseDiagnostics { recorder.current }

    /// The identity this coordinator acquires leases as.
    public var processIdentity: ProcessIdentity { identity }

    // MARK: - Acquire

    /// Claims `key` for `duration` seconds.
    ///
    /// Cases, in the order they are decided:
    ///
    /// 1. **Live lease held by us** → deadline extended, *same* epoch. A renewal is
    ///    not a handover, so writes already in flight stay valid.
    /// 2. **Live lease held by someone else** → refused. Nothing is written.
    /// 3. **Anything else** (no record, a tombstone, or a lapsed lease -- including
    ///    our own) → granted at a **new** epoch, strictly above both the record's
    ///    epoch and the floor reported by ``EpochFloorProvider``.
    ///
    /// - Throws: ``LeaseError/heldByAnotherProcess(holder:until:)``,
    ///   ``LeaseError/storeBusy(region:)``, ``LeaseError/invalidDuration(_:)``,
    ///   ``LeaseError/tokenSpaceExhausted``, or ``LeaseError/storageFailure(_:)`` --
    ///   the last of which can surface from the ``EpochFloorProvider`` read, since a
    ///   corrupt fenced envelope deliberately fails loudly rather than reporting no
    ///   floor.
    @discardableResult
    public func acquire(_ key: LeaseKey, for duration: TimeInterval) throws -> Lease {
        try LeaseLimits.validate(duration)
        let now = clock.wallTime
        let expiry = now.addingTimeInterval(duration)
        // Read outside the critical section: it touches a different store, and calling
        // into it while holding this key's mutex would nest two cross-process locks.
        //
        // A slightly stale floor is safe *while the record survives*: the floor only
        // ever grows, so a stale read yields a lower candidate, and the `max` against
        // the record below dominates it. The one interleaving it does not cover is a
        // stale floor read racing with concurrent destruction of the record -- read
        // floor F, a peer acquires F+1 and writes, the record is then lost, and this
        // call finds no record and issues F+1 as well. That is strictly narrower than
        // the disclosed residual gap (record lost *and* nothing ever written) but it is
        // not the same thing, so it is named here rather than folded into it.
        let floor = try epochFloor?.epochFloor()

        do {
            return try store.withExclusiveAccess(to: key) { current in
                if let current, current.isHeld(at: now) {
                    if current.holder == identity,
                       selfReacquisition.mayKeepEpoch(expired: false) {
                        let renewedRecord = current.renewed(until: expiry)
                        recorder.record { $0.renewals = Saturating.increment($0.renewals) }
                        return (.store(renewedRecord), self.lease(from: renewedRecord))
                    }
                    if current.holder != identity {
                        recorder.record {
                            $0.contentionRejections = Saturating.increment($0.contentionRejections)
                        }
                        throw LeaseError.heldByAnotherProcess(
                            holder: current.holder,
                            until: current.expiresAt
                        )
                    }
                }

                // Our own lapsed record, under an injected policy that wrongly says
                // the epoch may be kept. Only reachable from tests.
                if let current,
                   current.holder == identity,
                   !current.isReleased,
                   current.isExpired(at: now),
                   selfReacquisition.mayKeepEpoch(expired: true) {
                    let renewedRecord = current.renewed(until: expiry)
                    recorder.record { $0.renewals = Saturating.increment($0.renewals) }
                    return (.store(renewedRecord), self.lease(from: renewedRecord))
                }

                let token = try Self.nextEpoch(after: current?.token, floor: floor)
                let record = LeaseRecord(
                    key: key,
                    holder: identity,
                    token: token,
                    acquiredAt: now,
                    expiresAt: expiry
                )
                // A lapsed (not released) predecessor is a takeover; a tombstone or a
                // clean slate is an ordinary acquisition. The distinction matters
                // because `stealsFromExpiredLease` is the number that says "peers are
                // being declared dead", which is a different operational story from
                // "the key is busy".
                let wasTakeover = current.map { !$0.isReleased && $0.isExpired(at: now) } ?? false
                recorder.record {
                    if wasTakeover {
                        $0.stealsFromExpiredLease = Saturating.increment($0.stealsFromExpiredLease)
                    } else {
                        $0.acquisitions = Saturating.increment($0.acquisitions)
                    }
                }
                return (.store(record), self.lease(from: record))
            }
        } catch let error as LeaseError {
            if case .storeBusy = error {
                recorder.record {
                    $0.storeBusyRejections = Saturating.increment($0.storeBusyRejections)
                }
            }
            throw error
        }
    }

    /// The next epoch, above both the record's token and the resource's floor.
    ///
    /// `nil` for both means nothing has ever happened on this key, which is the only
    /// case where ``FencingToken/initial`` is safe to issue.
    static func nextEpoch(
        after recordToken: FencingToken?,
        floor: FencingToken?
    ) throws -> FencingToken {
        switch (recordToken, floor) {
        case (nil, nil):
            return .initial
        case let (token?, nil):
            return try token.next()
        case let (nil, floorToken?):
            return try floorToken.next()
        case let (token?, floorToken?):
            return try max(token, floorToken).next()
        }
    }

    // MARK: - Renew

    /// Extends `lease` by `duration` seconds, keeping its epoch.
    ///
    /// Fails with ``LeaseError/notHolder(key:presented:current:)`` if the epoch is no
    /// longer current -- i.e. someone stole the lease while this process was not
    /// looking, or this process released it. Renewal deliberately does *not* fall
    /// back to acquiring a new epoch: a caller that has been fenced needs to find out
    /// and re-plan, not be handed a fresh token as though its previous work were
    /// still valid.
    public func renew(_ lease: Lease, for duration: TimeInterval) throws -> Lease {
        try LeaseLimits.validate(duration)
        let now = clock.wallTime
        let expiry = now.addingTimeInterval(duration)

        return try store.withExclusiveAccess(to: lease.key) { current in
            guard let current,
                  current.holder == identity,
                  current.token == lease.token,
                  !current.isReleased
            else {
                throw LeaseError.notHolder(
                    key: lease.key,
                    presented: lease.token,
                    current: current?.token
                )
            }
            let renewedRecord = current.renewed(until: expiry)
            recorder.record { $0.renewals = Saturating.increment($0.renewals) }
            return (.store(renewedRecord), self.lease(from: renewedRecord))
        }
    }

    // MARK: - Release

    /// Relinquishes `lease`, making the key immediately available.
    ///
    /// Leaves a tombstone rather than deleting the record, so the epoch sequence
    /// stays monotonic -- see ``LeaseRecord/isReleased``.
    ///
    /// A release is only honoured for the *current* epoch. A fenced holder releasing
    /// would otherwise free the key out from under the process that legitimately took
    /// over, turning a caught staleness bug into a real mutual-exclusion violation.
    public func release(_ lease: Lease) throws {
        try store.withExclusiveAccess(to: lease.key) { current in
            guard let current,
                  current.holder == identity,
                  current.token == lease.token,
                  !current.isReleased
            else {
                throw LeaseError.notHolder(
                    key: lease.key,
                    presented: lease.token,
                    current: current?.token
                )
            }
            recorder.record { $0.releases = Saturating.increment($0.releases) }
            return (.store(current.releasedTombstone()), ())
        }
    }

    // MARK: - Inspect

    /// Reads the current record without modifying it.
    ///
    /// May return a tombstone (``LeaseRecord/isReleased`` is `true`), which means the
    /// key is *available* and the token is the high-water mark of the epoch sequence.
    /// Use ``LeaseRecord/isHeld(at:)`` to ask the question most callers mean.
    public func inspect(_ key: LeaseKey) throws -> LeaseRecord? {
        try store.withExclusiveAccess(to: key) { current in
            (.leave, current)
        }
    }

    /// Whether anyone holds `key` right now.
    public func isHeld(_ key: LeaseKey) throws -> Bool {
        let now = clock.wallTime
        return try inspect(key)?.isHeld(at: now) ?? false
    }

    /// Runs `body` while holding `key`, releasing on every exit path.
    ///
    /// The release is best-effort by design: if `body` overran the lease and a peer
    /// took over, the release correctly fails with
    /// ``LeaseError/notHolder(key:presented:current:)`` and that failure must not mask
    /// whatever `body` threw or returned. The caller learns it was fenced from the
    /// write path, which is the only place the information is actionable.
    public func withLease<T>(
        _ key: LeaseKey,
        for duration: TimeInterval,
        _ body: (Lease) throws -> T
    ) throws -> T {
        let held = try acquire(key, for: duration)
        defer { try? release(held) }
        return try body(held)
    }

    // MARK: - Helpers

    private func lease(from record: LeaseRecord) -> Lease {
        Lease(
            key: record.key,
            token: record.token,
            holder: record.holder,
            expiresAt: record.expiresAt
        )
    }
}
