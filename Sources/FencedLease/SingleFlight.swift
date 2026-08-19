import Foundation

// MARK: - Outcome

/// How a single-flight request was satisfied.
///
/// The distinction is not cosmetic: `.computed` is the caller that paid the cost,
/// and the ratio of `.reused` to `.computed` is the only evidence that the
/// coalescing is working at all. A system where every caller reports `.computed`
/// is a system with no coalescing and no error message saying so.
public enum SingleFlightOutcome<Value: Sendable>: Sendable {

    /// This caller performed the computation.
    case computed(Value)

    /// A peer -- in this process or another -- had already produced the value.
    case reused(Value)

    /// No value appeared within the caller's wait budget. The peer holding the
    /// lease may still be working; the caller decides whether to degrade or retry.
    case timedOut

    /// The value, if one was obtained.
    public var value: Value? {
        switch self {
        case let .computed(value), let .reused(value):
            return value
        case .timedOut:
            return nil
        }
    }

    /// Reinterprets a leader's outcome from a follower's point of view: the
    /// follower did not do the work, whatever the leader reports.
    func asReused() -> SingleFlightOutcome<Value> {
        switch self {
        case let .computed(value), let .reused(value):
            return .reused(value)
        case .timedOut:
            return .timedOut
        }
    }
}

// MARK: - CrossProcessSingleFlight

/// Ensures an expensive computation runs once across every process sharing a
/// container, not once per process.
///
/// The motivating case is an app and its extensions all wanting the same derived
/// artifact for the same input -- a thumbnail, a digest, an embedding for a shared
/// item. Without coordination, a share extension and the host app handed the same
/// URL will each do the whole job, and then race to publish two results.
///
/// Two layers of deduplication, because they solve different problems:
///
/// - **In-process**, via ``inFlight``: concurrent `Task`s in one process await a
///   single leader. This is load-bearing, not an optimisation. Every task in one
///   process shares a ``ProcessIdentity``, so without this map they would all hit
///   `acquire`'s *renewal* branch -- each one would be handed the same live lease and
///   every one of them would compute. The lease cannot deduplicate callers it cannot
///   tell apart.
/// - **Cross-process**, via the lease: exactly one process computes; the others wait
///   for the published envelope. This is the part that needs the fence, because a
///   slow leader can be superseded mid-computation.
///
/// ## Cancellation
///
/// The leader runs in an unstructured `Task`, which does not inherit cancellation. If
/// the caller that installed it is cancelled while awaiting, the cleanup clears the
/// entry while the leader keeps computing, and a later caller installs a second leader
/// -- so both compute. Safety is untouched (the fence still holds and only one write
/// wins); the "runs once" guarantee degrades to "runs once unless a leader's caller is
/// cancelled". Structured cancellation propagation would fix it and would also mean one
/// cancelled caller cancels the work every other caller is waiting on, which is worse.
///
/// ## A hazard worth naming
///
/// The leader task calls ``LeaseCoordinator/acquire(_:for:)``, which is synchronous
/// and, with a file-backed store, can spin in a bounded `usleep` retry while a peer
/// holds the short critical section. That occupies a cooperative-pool thread for up
/// to the store's budget (default 250ms, capped at 5s). It is bounded and small, but
/// it is real: a caller that must never block a pool thread should drive `acquire`
/// from a dedicated thread rather than relying on this type.
public actor CrossProcessSingleFlight<Value: Codable & Sendable> {

    private let coordinator: LeaseCoordinator
    private let writer: FencedWriter<Value>
    private let clock: any LeaseClock
    private let recorder: DiagnosticsRecorder

    /// How long to wait between checks for a peer's published result.
    private let pollInterval: TimeInterval

    /// In-flight leaders, keyed by resource.
    ///
    /// The `generation` makes cleanup safe across the `await` in
    /// ``value(for:leaseDuration:maxWait:staleAfter:compute:)``: a resuming caller
    /// must only clear the entry *it* installed, never a newer leader that
    /// replaced it while it was suspended. A `UUID` rather than a counter so there
    /// is no exhaustion case to reason about -- a saturating counter would let two
    /// leaders compare equal at the ceiling, reintroducing the very bug this
    /// guards against.
    private var inFlight: [LeaseKey: InFlightWork] = [:]

    private struct InFlightWork {
        let generation: UUID
        let task: Task<SingleFlightOutcome<Value>, Error>
    }

    public init(
        coordinator: LeaseCoordinator,
        writer: FencedWriter<Value>,
        clock: any LeaseClock = SystemLeaseClock(),
        recorder: DiagnosticsRecorder = DiagnosticsRecorder(),
        pollInterval: TimeInterval = 0.02
    ) {
        self.coordinator = coordinator
        self.writer = writer
        self.clock = clock
        self.recorder = recorder
        self.pollInterval = Saturating.clamp(pollInterval, to: 0.001...1.0)
    }

    public var diagnostics: LeaseDiagnostics { recorder.current }

    /// Returns the value for `key`, computing it at most once across all peers.
    ///
    /// - Parameters:
    ///   - leaseDuration: How long the computing peer claims the key. Must exceed
    ///     the expected compute time, or the leader will be fenced by a peer that
    ///     reasonably concluded it had died.
    ///   - maxWait: How long a non-computing caller waits for the result.
    ///   - staleAfter: An existing value older than this is recomputed. `nil`
    ///     means any existing value is acceptable.
    ///   - compute: Run by the winning caller only.
    public func value(
        for key: LeaseKey,
        leaseDuration: TimeInterval,
        maxWait: TimeInterval,
        staleAfter: TimeInterval? = nil,
        compute: @escaping @Sendable () async throws -> Value
    ) async throws -> SingleFlightOutcome<Value> {

        // Fast path: somebody already published something acceptable.
        if let fresh = try currentValueIfFresh(staleAfter: staleAfter) {
            recorder.record { $0.singleFlightReuses = Saturating.increment($0.singleFlightReuses) }
            return .reused(fresh)
        }

        // In-process follower: join the existing leader instead of contending on the
        // cross-process mutex. No suspension between the lookup and the `await`, so
        // this cannot miss a leader that is about to be installed.
        if let existing = inFlight[key] {
            let outcome = try await existing.task.value
            // The leader's value is accepted regardless of this follower's
            // `staleAfter`, and that is correct rather than lax: the leader computed it
            // during *this* call, so it is as fresh as anything this caller could
            // obtain by recomputing. Re-checking the store's timestamp here instead
            // would let a forward wall-clock step between the leader's write and this
            // resumption discard a value that was just produced -- turning a
            // successful computation into `.timedOut` on a clock skew, which is
            // precisely the safety-vs-liveness line this package promises not to
            // cross.
            //
            // Only count a reuse when a value actually came back; a leader that timed
            // out did not produce anything to reuse.
            if outcome.value != nil {
                recorder.record {
                    $0.singleFlightReuses = Saturating.increment($0.singleFlightReuses)
                }
            }
            return outcome.asReused()
        }

        let myGeneration = UUID()

        // The task body deliberately touches nothing actor-isolated -- only
        // `Sendable` collaborators -- so the leader cannot deadlock against, or
        // observe torn state from, the actor it was launched inside.
        let coordinator = self.coordinator
        let writer = self.writer
        let clock = self.clock
        let recorder = self.recorder
        let pollInterval = self.pollInterval

        let task = Task<SingleFlightOutcome<Value>, Error> {
            try await Self.runLeader(
                key: key,
                leaseDuration: leaseDuration,
                maxWait: maxWait,
                staleAfter: staleAfter,
                pollInterval: pollInterval,
                coordinator: coordinator,
                writer: writer,
                clock: clock,
                recorder: recorder,
                compute: compute
            )
        }
        inFlight[key] = InFlightWork(generation: myGeneration, task: task)

        // Runs on resume, on the actor, whether the task succeeded, threw, or was
        // cancelled. The generation check is the reentrancy guard.
        defer { clearInFlight(key, ifGeneration: myGeneration) }

        return try await task.value
    }

    // MARK: - Actor-isolated helpers

    /// Number of leaders currently installed. Exposed so tests can assert that
    /// cleanup actually happens and that ``clearInFlight(_:ifGeneration:)``'s guard
    /// refuses a foreign generation.
    var inFlightCount: Int { inFlight.count }

    /// Removes this caller's leader entry, and only this caller's.
    ///
    /// The generation check is defence in depth rather than a fix for a reachable
    /// bug: with the current call graph a follower joins the existing leader rather
    /// than installing a new one, so an entry should not be replaced under a
    /// suspended caller. It is kept because the alternative -- an unconditional
    /// `inFlight[key] = nil` after an `await` -- is correct only by accident of that
    /// call graph, and would silently start evicting live leaders the first time
    /// someone added a path that replaces an entry.
    func clearInFlight(_ key: LeaseKey, ifGeneration generation: UUID) {
        guard inFlight[key]?.generation == generation else { return }
        inFlight[key] = nil
    }

    private func currentValueIfFresh(staleAfter: TimeInterval?) throws -> Value? {
        try Self.publishedValueIfFresh(
            writer: writer,
            clock: clock,
            staleAfter: staleAfter
        )
    }

    // MARK: - Leader

    private static func runLeader(
        key: LeaseKey,
        leaseDuration: TimeInterval,
        maxWait: TimeInterval,
        staleAfter: TimeInterval?,
        pollInterval: TimeInterval,
        coordinator: LeaseCoordinator,
        writer: FencedWriter<Value>,
        clock: any LeaseClock,
        recorder: DiagnosticsRecorder,
        compute: @Sendable () async throws -> Value
    ) async throws -> SingleFlightOutcome<Value> {

        let lease: Lease
        do {
            lease = try coordinator.acquire(key, for: leaseDuration)
        } catch LeaseError.heldByAnotherProcess {
            // Another *process* is computing. Wait for its envelope.
            return try await waitForPeer(
                maxWait: maxWait,
                pollInterval: pollInterval,
                staleAfter: staleAfter,
                writer: writer,
                clock: clock,
                recorder: recorder
            )
        }

        // `defer`, not a release at each exit. Releasing only on the paths that were
        // thought of leaks the lease on the ones that were not -- and a leaked lease
        // is not a small bug: the key stays claimed for the whole `leaseDuration`,
        // so a peer is locked out for what may be hours. The reachable leaks this
        // replaces were a `storageFailure` from the double-check read below and a
        // non-`.fenced` write failure, both of which are exactly the corrupt-envelope
        // path the package treats as a loud, expected error.
        defer { try? coordinator.release(lease) }

        // Double-check after acquiring: a peer may have published between the fast
        // path and this acquisition. Skipping this check is how a "single"-flight ends
        // up doing the work twice under load.
        if let fresh = try publishedValueIfFresh(
            writer: writer, clock: clock, staleAfter: staleAfter
        ) {
            recorder.record { $0.singleFlightReuses = Saturating.increment($0.singleFlightReuses) }
            return .reused(fresh)
        }

        let computed = try await compute()

        do {
            try writer.write(computed, using: lease)
        } catch LeaseError.fenced {
            // The computation overran the lease and a peer took over. The peer's value
            // is the authoritative one -- returning this caller's stale result would
            // defeat the fence it just tripped.
            if let peerValue = try publishedValueIfFresh(
                writer: writer, clock: clock, staleAfter: nil
            ) {
                recorder.record {
                    $0.singleFlightReuses = Saturating.increment($0.singleFlightReuses)
                }
                return .reused(peerValue)
            }
            return .timedOut
        }

        recorder.record {
            $0.singleFlightComputations = Saturating.increment($0.singleFlightComputations)
        }
        return .computed(computed)
    }

    private static func waitForPeer(
        maxWait: TimeInterval,
        pollInterval: TimeInterval,
        staleAfter: TimeInterval?,
        writer: FencedWriter<Value>,
        clock: any LeaseClock,
        recorder: DiagnosticsRecorder
    ) async throws -> SingleFlightOutcome<Value> {

        // Bounded by attempt count rather than by a clock reading, so the loop
        // terminates even under an injected clock that never advances -- which is
        // exactly how the tests drive it.
        let budget = Saturating.clamp(maxWait, to: 0...LeaseLimits.maximumDuration)
        let attempts = Saturating.int(
            from: (budget / pollInterval).rounded(.up),
            clampedTo: 0...10_000
        )

        var remaining = attempts
        while remaining > 0 {
            remaining -= 1
            try await Task.sleep(nanoseconds: Saturating.nanoseconds(fromSeconds: pollInterval))
            if let value = try publishedValueIfFresh(
                writer: writer, clock: clock, staleAfter: staleAfter
            ) {
                recorder.record {
                    $0.singleFlightReuses = Saturating.increment($0.singleFlightReuses)
                }
                return .reused(value)
            }
        }
        return .timedOut
    }

    private static func publishedValueIfFresh(
        writer: FencedWriter<Value>,
        clock: any LeaseClock,
        staleAfter: TimeInterval?
    ) throws -> Value? {
        guard let (value, envelope) = try writer.readEnvelope() else { return nil }
        guard let staleAfter else { return value }
        guard staleAfter.isFinite, staleAfter > 0 else { return nil }
        let age = clock.wallTime.timeIntervalSince(envelope.writtenAt)
        // A negative age means the envelope is stamped in the future -- a wall
        // clock that moved backwards. Treating it as fresh is the conservative
        // reading: recomputing on every clock skew would be a stampede triggered
        // by an NTP correction.
        guard age <= staleAfter else { return nil }
        return value
    }
}
