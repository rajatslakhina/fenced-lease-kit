import Foundation
import XCTest
@testable import FencedLease

private struct Embedding: Codable, Sendable, Equatable {
    let source: String
    let dimensions: Int
}

final class SingleFlightTests: XCTestCase {

    private var store: InMemoryLeaseStore!
    private var storage: InMemoryFencedStorage!
    private var clock: ManualLeaseClock!
    private var key: LeaseKey!
    private var writer: FencedWriter<Embedding>!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = InMemoryLeaseStore()
        storage = InMemoryFencedStorage()
        clock = ManualLeaseClock(wallTime: Date(timeIntervalSince1970: 1_000))
        key = try requireKey("item.embedding")
        writer = FencedWriter<Embedding>(storage: storage, clock: clock)
    }

    private func makeCoordinator(_ label: String) -> LeaseCoordinator {
        LeaseCoordinator(
            store: store,
            identity: identity(label),
            clock: clock,
            // Wired the way real callers should: without it the epoch sequence would
            // restart whenever the lease record went away.
            epochFloor: writer
        )
    }

    private func makeFlight(_ label: String) -> CrossProcessSingleFlight<Embedding> {
        CrossProcessSingleFlight(
            coordinator: makeCoordinator(label),
            writer: writer,
            clock: clock,
            pollInterval: 0.005
        )
    }

    // MARK: - Coalescing

    func testConcurrentCallersInOneProcessComputeExactlyOnce() async throws {
        let flight = makeFlight("app")
        let counter = CallCounter()
        let key = self.key!
        let callers = 24

        let outcomes = await withTaskGroup(
            of: SingleFlightOutcome<Embedding>?.self
        ) { group in
            for _ in 0..<callers {
                group.addTask {
                    try? await flight.value(
                        for: key,
                        leaseDuration: 60,
                        maxWait: 1
                    ) {
                        await counter.increment()
                        // A real suspension, so the callers genuinely overlap
                        // rather than running to completion one at a time.
                        try await Task.sleep(nanoseconds: 20_000_000)
                        return Embedding(source: "model", dimensions: 64)
                    }
                }
            }
            var collected: [SingleFlightOutcome<Embedding>?] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        let computeCount = await counter.count
        XCTAssertEqual(computeCount, 1, "the expensive work must run once, not \(computeCount) times")
        XCTAssertEqual(outcomes.count, callers)
        // Every caller gets the value, but only one claims to have produced it.
        let computed = outcomes.filter { if case .computed = $0 { return true } else { return false } }
        XCTAssertEqual(computed.count, 1)
        for outcome in outcomes {
            XCTAssertEqual(outcome?.value, Embedding(source: "model", dimensions: 64))
        }
    }

    func testASubsequentCallReusesThePublishedValueWithoutRecomputing() async throws {
        let flight = makeFlight("app")
        let counter = CallCounter()

        let first = try await flight.value(for: key, leaseDuration: 60, maxWait: 1) {
            await counter.increment()
            return Embedding(source: "model", dimensions: 64)
        }
        let second = try await flight.value(for: key, leaseDuration: 60, maxWait: 1) {
            await counter.increment()
            return Embedding(source: "should-not-run", dimensions: 0)
        }

        let computeCount = await counter.count
        if case .computed = first {} else { XCTFail("the first caller should compute") }
        if case .reused = second {} else { XCTFail("the second caller should reuse") }
        XCTAssertEqual(computeCount, 1)
        XCTAssertEqual(second.value, Embedding(source: "model", dimensions: 64))
    }

    func testTheLeaseIsReleasedSoASecondRoundCanProceed() async throws {
        let flight = makeFlight("app")
        _ = try await flight.value(for: key, leaseDuration: 60, maxWait: 1) {
            Embedding(source: "first", dimensions: 1)
        }
        // If the leader had leaked its lease, a recompute would be blocked for the
        // full 60s rather than proceeding immediately. The record survives as a
        // tombstone -- that is what keeps the epoch sequence monotonic -- but nobody
        // holds it.
        XCTAssertEqual(store.snapshot[key]?.isReleased, true)

        // Age the published value past the staleness bound, so the second round
        // genuinely needs to take the lease again.
        clock.advance(by: 100)
        let recomputed = try await flight.value(
            for: key, leaseDuration: 60, maxWait: 1, staleAfter: 30
        ) {
            Embedding(source: "second", dimensions: 2)
        }
        if case .computed = recomputed {} else { XCTFail("a stale value must be recomputed") }
        XCTAssertEqual(recomputed.value?.source, "second")
    }

    // MARK: - Staleness

    func testAFreshEnoughValueIsReusedAndAStaleOneIsNot() async throws {
        let flight = makeFlight("app")
        _ = try await flight.value(for: key, leaseDuration: 60, maxWait: 1) {
            Embedding(source: "original", dimensions: 1)
        }

        clock.advance(by: 10)
        let reused = try await flight.value(
            for: key, leaseDuration: 60, maxWait: 1, staleAfter: 30
        ) {
            Embedding(source: "recomputed", dimensions: 2)
        }
        XCTAssertEqual(reused.value?.source, "original")

        clock.advance(by: 100)
        let recomputed = try await flight.value(
            for: key, leaseDuration: 60, maxWait: 1, staleAfter: 30
        ) {
            Embedding(source: "recomputed", dimensions: 2)
        }
        XCTAssertEqual(recomputed.value?.source, "recomputed")
    }

    func testAnEnvelopeStampedInTheFutureIsTreatedAsFreshRatherThanTriggeringAStampede() async throws {
        let flight = makeFlight("app")
        _ = try await flight.value(for: key, leaseDuration: 60, maxWait: 1) {
            Embedding(source: "original", dimensions: 1)
        }

        // The wall clock moves backwards -- an NTP correction. The envelope is now
        // stamped in the future, giving it a negative age.
        clock.rewindWallClock(by: 5_000)

        let outcome = try await flight.value(
            for: key, leaseDuration: 60, maxWait: 1, staleAfter: 30
        ) {
            Embedding(source: "stampede", dimensions: 0)
        }
        // Recomputing on every clock skew would turn one NTP correction into a
        // thundering herd across every process at once.
        XCTAssertEqual(outcome.value?.source, "original")
    }

    // MARK: - The leader loses the race

    func testALeaderThatOverrunsItsLeaseYieldsToThePeerThatSupersededIt() async throws {
        let flight = makeFlight("app")
        let peer = makeCoordinator("widget")
        let clock = self.clock!
        let writer = self.writer!
        let key = self.key!

        let outcome = try await flight.value(for: key, leaseDuration: 30, maxWait: 0.05) {
            // Inside the computation, wall time passes and a peer concludes this
            // leader is gone, takes the key, and publishes.
            clock.advance(by: 31)
            let peerLease = try peer.acquire(key, for: 30)
            try writer.write(Embedding(source: "widget", dimensions: 16), using: peerLease)
            try peer.release(peerLease)
            return Embedding(source: "app", dimensions: 64)
        }

        // The leader's own result is discarded: it tripped the fence, so the peer's
        // value is authoritative. Returning the leader's result here would defeat
        // the fence it just triggered.
        if case .reused = outcome {} else { XCTFail("expected the peer's value, got \(outcome)") }
        XCTAssertEqual(outcome.value, Embedding(source: "widget", dimensions: 16))
        XCTAssertEqual(try writer.read(), Embedding(source: "widget", dimensions: 16))
        XCTAssertEqual(writer.diagnostics.fencedWriteRejections, 1)
    }

    // MARK: - Failure paths

    func testAThrowingComputationReleasesTheLeaseImmediately() async throws {
        let flight = makeFlight("app")
        struct Boom: Error {}

        do {
            _ = try await flight.value(for: key, leaseDuration: 3_600, maxWait: 0.05) {
                throw Boom()
            }
            XCTFail("the error should propagate to the caller")
        } catch is Boom {
            // expected
        }

        // Holding the lease for the full hour after a failure would block every peer
        // from retrying. The tombstone means the record is present but unheld.
        XCTAssertEqual(store.snapshot[key]?.isReleased, true)
        let retry = try await flight.value(for: key, leaseDuration: 60, maxWait: 0.05) {
            Embedding(source: "retry", dimensions: 8)
        }
        if case .computed = retry {} else { XCTFail("a retry must be able to proceed") }
    }

    func testAWaiterTimesOutWhenTheHoldingPeerNeverPublishes() async throws {
        let flight = makeFlight("app")
        // A peer takes the key and never publishes -- from this caller's side,
        // indistinguishable from a peer doing very slow work.
        let squatter = makeCoordinator("widget")
        _ = try squatter.acquire(key, for: 3_600)

        let outcome = try await flight.value(for: key, leaseDuration: 60, maxWait: 0.05) {
            Embedding(source: "should-not-run", dimensions: 0)
        }

        if case .timedOut = outcome {} else { XCTFail("expected a timeout, got \(outcome)") }
        XCTAssertNil(outcome.value)
    }

    func testAWaiterPicksUpAValueThatAppearsWhileItIsWaiting() async throws {
        let flight = makeFlight("app")
        let squatter = makeCoordinator("widget")
        let squatterLease = try squatter.acquire(key, for: 3_600)
        let writer = self.writer!
        let key = self.key!

        // A genuinely concurrent writer publishing mid-wait.
        let publisher = Task {
            try await Task.sleep(nanoseconds: 20_000_000)
            try writer.write(Embedding(source: "widget", dimensions: 32), using: squatterLease)
        }

        let outcome = try await flight.value(for: key, leaseDuration: 60, maxWait: 5) {
            Embedding(source: "should-not-run", dimensions: 0)
        }
        try await publisher.value

        if case .reused = outcome {} else { XCTFail("expected the peer's value, got \(outcome)") }
        XCTAssertEqual(outcome.value, Embedding(source: "widget", dimensions: 32))
    }

    // MARK: - The lease must never be leaked

    /// A leader that fails on a path other than `.fenced` must still release.
    ///
    /// Releasing only on the paths that were thought of leaks the lease on the ones
    /// that were not, and a leaked lease is not a small bug: the key stays claimed for
    /// the whole `leaseDuration`. The trigger here is a corrupt fenced envelope --
    /// which this package deliberately treats as a loud failure -- so without the fix
    /// the showpiece error path also locks the resource for hours.
    func testAStorageFailureDoesNotLeakTheLease() async throws {
        let failing = FailingFencedStorage()
        let failWriter = FencedWriter<Embedding>(storage: failing, clock: clock)
        let coordinator = LeaseCoordinator(
            store: store, identity: identity("app"), clock: clock, epochFloor: nil
        )
        let flight = CrossProcessSingleFlight(
            coordinator: coordinator, writer: failWriter, clock: clock, pollInterval: 0.005
        )
        // Entry 0 is the fast-path read, which happens *before* the lease is taken --
        // failing there proves nothing, because there is no lease to leak yet. Entry 1
        // is the double-check read that runs while the lease is held, which is the path
        // that used to leak.
        failing.failFromEntry(1)

        // A 24-hour lease, so a leak is unmistakable rather than a timing artefact.
        do {
            _ = try await flight.value(
                for: key, leaseDuration: LeaseLimits.maximumDuration, maxWait: 0.05
            ) {
                Embedding(source: "never", dimensions: 0)
            }
            XCTFail("the storage failure should propagate")
        } catch let error as LeaseError {
            guard case .storageFailure = error else {
                XCTFail("expected storageFailure, got \(error)")
                return
            }
        }

        XCTAssertEqual(
            try coordinator.isHeld(key), false,
            "the lease must be released even on an unanticipated error path"
        )
        XCTAssertEqual(store.snapshot[key]?.isReleased, true)

        // And a peer can proceed immediately rather than waiting out 24 hours.
        let peer = LeaseCoordinator(
            store: store, identity: identity("widget"), clock: clock
        )
        XCTAssertNoThrow(try peer.acquire(key, for: 60))
    }

    func testAThrowingComputationAlsoDoesNotLeakTheLease() async throws {
        let flight = makeFlight("app")
        struct Boom: Error {}
        _ = try? await flight.value(
            for: key, leaseDuration: LeaseLimits.maximumDuration, maxWait: 0.05
        ) {
            throw Boom()
        }
        XCTAssertEqual(store.snapshot[key]?.isReleased, true)
    }

    // MARK: - A follower keeps the leader's freshly computed value

    /// A forward wall-clock step between the leader's write and the follower's
    /// resumption must not discard a value that was just computed.
    ///
    /// The follower's `staleAfter` is about *cached* values, not about the value being
    /// produced by the call it is waiting on. Re-checking the store's timestamp here
    /// would turn a successful computation into `.timedOut` on a clock skew -- crossing
    /// the safety/liveness line this package promises not to cross.
    func testAFollowerKeepsTheLeadersValueEvenIfTheClockJumpsForward() async throws {
        let flight = makeFlight("app")
        let clock = self.clock!
        let key = self.key!
        let counter = CallCounter()

        let outcomes = await withTaskGroup(of: SingleFlightOutcome<Embedding>?.self) { group in
            for index in 0..<6 {
                group.addTask {
                    try? await flight.value(
                        for: key, leaseDuration: 60, maxWait: 5, staleAfter: 30
                    ) {
                        await counter.increment()
                        try await Task.sleep(nanoseconds: 20_000_000)
                        // The clock leaps far past the staleness bound while the
                        // leader is mid-computation.
                        if index >= 0 { clock.advance(by: 10_000) }
                        return Embedding(source: "fresh", dimensions: 64)
                    }
                }
            }
            var collected: [SingleFlightOutcome<Embedding>?] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        let computeCount = await counter.count
        XCTAssertEqual(computeCount, 1)
        for outcome in outcomes {
            XCTAssertEqual(
                outcome?.value, Embedding(source: "fresh", dimensions: 64),
                "a follower must not discard the value the leader just produced"
            )
        }
    }

    // MARK: - Leader bookkeeping

    func testTheLeaderEntryIsCleanedUpAfterSuccessAndAfterFailure() async throws {
        let flight = makeFlight("app")
        struct Boom: Error {}

        _ = try await flight.value(for: key, leaseDuration: 60, maxWait: 1) {
            Embedding(source: "ok", dimensions: 1)
        }
        var count = await flight.inFlightCount
        XCTAssertEqual(count, 0, "a successful leader must not leak its entry")

        clock.advance(by: 1_000)
        _ = try? await flight.value(for: key, leaseDuration: 60, maxWait: 1, staleAfter: 30) {
            throw Boom()
        }
        count = await flight.inFlightCount
        XCTAssertEqual(count, 0, "a failed leader must not leak its entry either")
    }

    /// Exercises the generation guard through the real method.
    ///
    /// Without the guard, `clearInFlight` would evict whatever entry happened to be
    /// present. This installs a live leader, calls the real cleanup with a *foreign*
    /// generation, and asserts the leader survives -- so replacing the guard with an
    /// unconditional removal fails here.
    func testClearingWithAForeignGenerationLeavesTheLeaderAlone() async throws {
        let flight = makeFlight("app")
        let key = self.key!
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        let leader = Task {
            try await flight.value(for: key, leaseDuration: 60, maxWait: 1) {
                started.signal()
                // Park until the assertions below have run.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        release.wait()
                        continuation.resume()
                    }
                }
                return Embedding(source: "model", dimensions: 64)
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)

        let before = await flight.inFlightCount
        XCTAssertEqual(before, 1, "a leader should be installed while computing")

        await flight.clearInFlight(key, ifGeneration: UUID())
        let after = await flight.inFlightCount
        XCTAssertEqual(
            after, 1,
            "a foreign generation must not evict the live leader; without the guard this is 0"
        )

        release.signal()
        _ = try await leader.value
        let finally = await flight.inFlightCount
        XCTAssertEqual(finally, 0, "the leader's own generation must clean up")
    }

    // MARK: - Outcome type

    func testOutcomeValueAccessorAndFollowerMapping() {
        let value = Embedding(source: "x", dimensions: 1)
        XCTAssertEqual(SingleFlightOutcome.computed(value).value, value)
        XCTAssertEqual(SingleFlightOutcome.reused(value).value, value)
        XCTAssertNil(SingleFlightOutcome<Embedding>.timedOut.value)

        // A follower did not do the work, whatever the leader reports.
        if case .reused = SingleFlightOutcome.computed(value).asReused() {} else {
            XCTFail("a leader's `computed` must present as `reused` to a follower")
        }
        if case .timedOut = SingleFlightOutcome<Embedding>.timedOut.asReused() {} else {
            XCTFail("a timeout stays a timeout")
        }
    }

    // MARK: - Cross-process single flight through real files

    func testSingleFlightCoalescesAcrossSeparateStoreInstances() async throws {
        let directory = try TemporaryDirectory()
        let fileStore = try FileLeaseStore(directory: directory.url, clock: SystemLeaseClock())
        let fileStorage = try FileFencedStorage(
            directory: directory.url,
            resourceName: key,
            clock: SystemLeaseClock()
        )
        let fileWriter = FencedWriter<Embedding>(storage: fileStorage, clock: clock)
        let counter = CallCounter()
        let key = self.key!
        let clock = self.clock!

        // Two independent "processes" racing for the same key at the same moment. They
        // share one `FileLeaseStore` *value*, which is fine and is the point:
        // `FileMutex` opens a fresh descriptor per entry, so serialisation comes from
        // the kernel rather than from the Swift object. What makes them distinct peers
        // is their `ProcessIdentity`.
        let flights = (0..<2).map { index in
            CrossProcessSingleFlight(
                coordinator: LeaseCoordinator(
                    store: fileStore,
                    identity: identity("process-\(index)"),
                    clock: clock,
                    epochFloor: fileWriter
                ),
                writer: fileWriter,
                clock: clock,
                pollInterval: 0.005
            )
        }

        let outcomes = await withTaskGroup(of: SingleFlightOutcome<Embedding>?.self) { group in
            for flight in flights {
                group.addTask {
                    try? await flight.value(for: key, leaseDuration: 60, maxWait: 5) {
                        await counter.increment()
                        try await Task.sleep(nanoseconds: 30_000_000)
                        return Embedding(source: "model", dimensions: 64)
                    }
                }
            }
            var collected: [SingleFlightOutcome<Embedding>?] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        let computeCount = await counter.count
        XCTAssertEqual(computeCount, 1, "the work must not be duplicated per process")
        for outcome in outcomes {
            XCTAssertEqual(outcome?.value, Embedding(source: "model", dimensions: 64))
        }
    }
}
