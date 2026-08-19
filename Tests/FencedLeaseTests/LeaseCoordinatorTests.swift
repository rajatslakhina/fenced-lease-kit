import Foundation
import XCTest
@testable import FencedLease

final class LeaseCoordinatorTests: XCTestCase {

    private var store: InMemoryLeaseStore!
    private var clock: ManualLeaseClock!
    private var key: LeaseKey!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = InMemoryLeaseStore()
        clock = ManualLeaseClock(wallTime: Date(timeIntervalSince1970: 1_000))
        key = try requireKey("shared.index")
    }

    private func coordinator(_ label: String) -> LeaseCoordinator {
        LeaseCoordinator(store: store, identity: identity(label), clock: clock)
    }

    // MARK: - Acquisition

    func testFirstAcquisitionStartsAtTheInitialEpoch() throws {
        let lease = try coordinator("app").acquire(key, for: 30)
        XCTAssertEqual(lease.token, .initial)
        XCTAssertEqual(lease.expiresAt, clock.wallTime.addingTimeInterval(30))
    }

    func testALiveLeaseBlocksAPeerAndWritesNothing() throws {
        let app = coordinator("app")
        let widget = coordinator("widget")
        let held = try app.acquire(key, for: 30)

        let recordBefore = store.snapshot[key]
        assertLeaseError(
            { _ = try widget.acquire(self.key, for: 30) },
            { if case .heldByAnotherProcess = $0 { return true } else { return false } },
            "a live lease must block a peer"
        )
        // The refusal must be a true no-op. A failed acquire that still touched the
        // record would let a rejected peer bump the epoch and fence the legitimate
        // holder out of its own lease.
        XCTAssertEqual(store.snapshot[key], recordBefore)
        XCTAssertEqual(store.snapshot[key]?.token, held.token)
        XCTAssertEqual(widget.diagnostics.contentionRejections, 1)
    }

    func testAPeerStealsAnExpiredLeaseAtTheNextEpoch() throws {
        let app = coordinator("app")
        let widget = coordinator("widget")
        _ = try app.acquire(key, for: 30)

        clock.advance(by: 31)
        let stolen = try widget.acquire(key, for: 30)

        XCTAssertEqual(stolen.token, FencingToken(rawValue: 2))
        XCTAssertEqual(widget.diagnostics.stealsFromExpiredLease, 1)
    }

    func testRenewalKeepsTheSameEpoch() throws {
        let app = coordinator("app")
        let first = try app.acquire(key, for: 30)
        clock.advance(by: 10)
        let second = try app.acquire(key, for: 30)

        // A renewal is not a handover, so writes already in flight must stay valid.
        XCTAssertEqual(second.token, first.token)
        XCTAssertEqual(app.diagnostics.renewals, 1)
        XCTAssertEqual(app.diagnostics.stealsFromExpiredLease, 0)
    }

    /// The invariant the whole package exists for.
    func testReacquiringAfterOwnExpiryBumpsTheEpoch() throws {
        let app = coordinator("app")
        let original = try app.acquire(key, for: 30)

        // Models the process being SIGSTOPped past its own deadline -- routine on
        // iOS, not exotic.
        clock.advance(by: 31)
        let resumed = try app.acquire(key, for: 30)

        // The record still says "app", but the lease lapsed, and `app` cannot tell
        // whether a peer took over and released in the interim. Reusing the old
        // token would be exactly the bug the fence is meant to catch.
        XCTAssertGreaterThan(resumed.token, original.token)
        XCTAssertEqual(resumed.token, FencingToken(rawValue: 2))
        XCTAssertEqual(app.diagnostics.stealsFromExpiredLease, 1)
        XCTAssertEqual(app.diagnostics.renewals, 0)
    }

    /// Proves the invariant above is load-bearing by injecting the tempting-but-wrong
    /// policy into the **real** coordinator and showing what stops working.
    ///
    /// The harm is precise: crossing its own expiry must **invalidate the handles the
    /// process was holding before it was suspended**. A resumed process typically has
    /// state captured pre-suspension -- a `Lease` on a stack frame, in a closure, in a
    /// pending continuation -- and that state must not still be able to write, because
    /// the process cannot know what happened while it was stopped.
    ///
    /// Both halves are asserted below: the correct policy kills the old handle, the
    /// broken one leaves it live. Nothing here reimplements the coordinator; the same
    /// production `acquire` runs in both cases, with one injected decision differing.
    func testCrossingOwnExpiryMustInvalidateHandlesHeldBeforeTheSuspension() throws {
        // --- correct policy: the pre-suspension handle is dead ---
        let goodStorage = InMemoryFencedStorage()
        let goodWriter = FencedWriter<String>(storage: goodStorage, clock: clock)
        let correct = LeaseCoordinator(
            store: InMemoryLeaseStore(),
            identity: identity("app"),
            clock: clock,
            epochFloor: goodWriter
        )

        let handleBeforeSuspension = try correct.acquire(key, for: 30)
        clock.advance(by: 31)
        let handleAfterResume = try correct.acquire(key, for: 30)
        XCTAssertGreaterThan(handleAfterResume.token, handleBeforeSuspension.token)

        try goodWriter.write("after-resume", using: handleAfterResume)
        assertLeaseError(
            { try goodWriter.write("pre-suspension", using: handleBeforeSuspension) },
            { if case .fenced = $0 { return true } else { return false } },
            "the pre-suspension handle must be fenced once the epoch has moved"
        )
        XCTAssertEqual(try goodWriter.read(), "after-resume")

        // --- broken policy: the same handle is still live ---
        let badStorage = InMemoryFencedStorage()
        let badWriter = FencedWriter<String>(storage: badStorage, clock: clock)
        let broken = LeaseCoordinator(
            store: InMemoryLeaseStore(),
            identity: identity("app"),
            clock: clock,
            epochFloor: badWriter,
            selfReacquisition: HolderNameOnlySelfReacquisition()
        )

        let brokenBefore = try broken.acquire(key, for: 30)
        clock.advance(by: 31)
        let brokenAfter = try broken.acquire(key, for: 30)
        XCTAssertEqual(
            brokenAfter.token, brokenBefore.token,
            "the broken policy keeps the epoch across its own expiry"
        )

        try badWriter.write("after-resume", using: brokenAfter)
        // No fencing: the stale handle writes as though the suspension never happened,
        // and silently overwrites what the resumed process just published.
        XCTAssertNoThrow(try badWriter.write("pre-suspension", using: brokenBefore))
        XCTAssertEqual(
            try badWriter.read(), "pre-suspension",
            "with the broken policy a pre-suspension handle clobbers post-resume work"
        )
        XCTAssertEqual(badWriter.diagnostics.fencedWriteRejections, 0)
    }

    // MARK: - Epoch monotonicity (the invariant everything rests on)

    /// A release must not reset the epoch sequence.
    ///
    /// Deleting the record on release -- the obvious implementation -- restarts the
    /// next acquirer at epoch 1, below whatever mark the resource already holds. This
    /// is a regression test for exactly that bug.
    func testEpochNeverGoesBackwardsAcrossAnOrdinaryRelease() throws {
        let app = coordinator("app")
        let widget = coordinator("widget")

        let first = try app.acquire(key, for: 30)
        try app.release(first)
        let second = try widget.acquire(key, for: 30)

        XCTAssertGreaterThan(
            second.token, first.token,
            "an epoch was re-issued after a release: the fence is now broken in both directions"
        )
        // The tombstone is what makes that true.
        try widget.release(second)
        let record = try widget.inspect(key)
        XCTAssertEqual(record?.isReleased, true, "release must leave a tombstone, not delete")
        XCTAssertEqual(record?.token, second.token)
        XCTAssertEqual(try widget.isHeld(key), false, "a tombstoned key is available")
    }

    /// The full safety scenario the bug enabled: a stale holder writing over a newer
    /// value because both ended up holding the same epoch number.
    func testAStaleHolderCannotCollideWithANewHolderOnTheSameEpoch() throws {
        let storage = InMemoryFencedStorage()
        let writer = FencedWriter<String>(storage: storage, clock: clock)
        let app = LeaseCoordinator(
            store: store, identity: identity("app"), clock: clock, epochFloor: writer
        )
        let ext = LeaseCoordinator(
            store: store, identity: identity("ext"), clock: clock, epochFloor: writer
        )
        let widget = LeaseCoordinator(
            store: store, identity: identity("widget"), clock: clock, epochFloor: writer
        )

        // app takes the lease and is suspended before writing.
        let appLease = try app.acquire(key, for: 30)
        clock.advance(by: 31)
        // ext takes over, fails at its work, and releases cleanly.
        let extLease = try ext.acquire(key, for: 30)
        try ext.release(extLease)
        // widget acquires and publishes.
        let widgetLease = try widget.acquire(key, for: 30)
        try writer.write("widget", using: widgetLease)

        XCTAssertNotEqual(
            appLease.token, widgetLease.token,
            "two live processes must never hold the same epoch"
        )

        // app resumes and writes. It must be fenced.
        assertLeaseError(
            { try writer.write("app", using: appLease) },
            { if case .fenced = $0 { return true } else { return false } },
            "a stale holder must not be able to write"
        )
        XCTAssertEqual(try writer.read(), "widget", "the newer value must survive")
    }

    /// Losing the record entirely must not reset the sequence, provided the resource
    /// remembers.
    func testEpochSurvivesLosingTheLeaseRecordWhenAFloorIsWired() throws {
        let forgetful = ForgetfulLeaseStore()
        let storage = InMemoryFencedStorage()
        let writer = FencedWriter<String>(storage: storage, clock: clock)
        let app = LeaseCoordinator(
            store: forgetful, identity: identity("app"), clock: clock, epochFloor: writer
        )
        let widget = LeaseCoordinator(
            store: forgetful, identity: identity("widget"), clock: clock, epochFloor: writer
        )

        let stale = try app.acquire(key, for: 30)
        try writer.write("app", using: stale)

        // The container is wiped: crash between open and rename, or the OS reclaiming
        // space. The lease record is gone.
        forgetful.forgetEverything()
        XCTAssertNil(try widget.inspect(key))

        let fresh = try widget.acquire(key, for: 30)
        XCTAssertGreaterThan(
            fresh.token, stale.token,
            "the resource's high-water mark must carry the sequence when the record cannot"
        )
        try writer.write("widget", using: fresh)
        assertLeaseError(
            { try writer.write("app", using: stale) },
            { if case .fenced = $0 { return true } else { return false } },
            "the pre-wipe holder must still be fenced"
        )
    }

    /// The residual gap, asserted so it is a documented property rather than a
    /// surprise: with no floor wired, losing the record *does* restart the sequence.
    func testWithoutAFloorLosingTheRecordRestartsTheSequence() throws {
        let forgetful = ForgetfulLeaseStore()
        let app = LeaseCoordinator(
            store: forgetful, identity: identity("app"), clock: clock
        )
        let first = try app.acquire(key, for: 30)
        forgetful.forgetEverything()
        let second = try app.acquire(key, for: 30)

        // This is why `epochFloor` exists and why the docs call it strongly
        // recommended rather than optional-in-practice.
        XCTAssertEqual(second.token, first.token)
        XCTAssertEqual(second.token, .initial)
    }

    func testNextEpochTakesTheMaximumOfRecordAndFloor() throws {
        let five = FencingToken(rawValue: 5)
        let nine = FencingToken(rawValue: 9)
        XCTAssertEqual(try LeaseCoordinator.nextEpoch(after: nil, floor: nil), .initial)
        XCTAssertEqual(
            try LeaseCoordinator.nextEpoch(after: five, floor: nil).rawValue, 6
        )
        XCTAssertEqual(
            try LeaseCoordinator.nextEpoch(after: nil, floor: nine).rawValue, 10
        )
        // The floor wins when it is ahead...
        XCTAssertEqual(
            try LeaseCoordinator.nextEpoch(after: five, floor: nine).rawValue, 10
        )
        // ...and the record wins when it is ahead, which is the ordinary case.
        XCTAssertEqual(
            try LeaseCoordinator.nextEpoch(after: nine, floor: five).rawValue, 10
        )
        assertLeaseError(
            { _ = try LeaseCoordinator.nextEpoch(
                after: FencingToken(rawValue: UInt64.max), floor: nil
            ) },
            { $0 == .tokenSpaceExhausted },
            "exhaustion must surface rather than wrap"
        )
    }

    func testAcquiringAboveAFloorEvenOnAnUntouchedKey() throws {
        let floor = StubEpochFloor(FencingToken(rawValue: 41))
        let app = LeaseCoordinator(
            store: store, identity: identity("app"), clock: clock, epochFloor: floor
        )
        XCTAssertEqual(try app.acquire(key, for: 30).token.rawValue, 42)
    }

    // MARK: - Renew

    func testRenewFailsOnceTheEpochHasMoved() throws {
        let app = coordinator("app")
        let widget = coordinator("widget")
        let stale = try app.acquire(key, for: 30)

        clock.advance(by: 31)
        _ = try widget.acquire(key, for: 30)

        // Renewal deliberately does not fall back to a fresh epoch: a fenced caller
        // needs to learn it lost, not be handed a new token as though its work were
        // still valid.
        assertLeaseError(
            { _ = try app.renew(stale, for: 30) },
            { if case .notHolder = $0 { return true } else { return false } },
            "renewing a superseded epoch must fail"
        )
    }

    func testRenewExtendsTheDeadlineWithoutChangingTheEpoch() throws {
        let app = coordinator("app")
        let held = try app.acquire(key, for: 30)
        clock.advance(by: 5)
        let renewed = try app.renew(held, for: 60)

        XCTAssertEqual(renewed.token, held.token)
        XCTAssertEqual(renewed.expiresAt, clock.wallTime.addingTimeInterval(60))
    }

    // MARK: - Release

    func testReleaseByTheHolderFreesTheKeyImmediately() throws {
        let app = coordinator("app")
        let widget = coordinator("widget")
        let held = try app.acquire(key, for: 3_600)
        try app.release(held)

        // The record survives as a tombstone -- see
        // `testEpochNeverGoesBackwardsAcrossAnOrdinaryRelease` for why deleting it
        // would be a safety bug -- but the key is available immediately, without
        // waiting out the hour that was granted.
        XCTAssertEqual(store.snapshot[key]?.isReleased, true)
        XCTAssertEqual(try app.isHeld(key), false)
        XCTAssertNoThrow(try widget.acquire(key, for: 30))
        XCTAssertEqual(app.diagnostics.releases, 1)
    }

    func testReleaseByASupersededHolderIsRefusedAndLeavesTheRecordIntact() throws {
        let app = coordinator("app")
        let widget = coordinator("widget")
        let stale = try app.acquire(key, for: 30)
        clock.advance(by: 31)
        let current = try widget.acquire(key, for: 30)

        assertLeaseError(
            { try app.release(stale) },
            { if case .notHolder = $0 { return true } else { return false } },
            "a superseded holder must not be able to release"
        )
        // Honouring that release would delete the record out from under the
        // legitimate holder -- turning a caught staleness bug into a real
        // mutual-exclusion violation.
        XCTAssertEqual(store.snapshot[key]?.token, current.token)
    }

    // MARK: - Duration validation

    func testInvalidDurationsAreRejectedBeforeAnythingIsWritten() throws {
        let app = coordinator("app")
        for bad in [0, -1, TimeInterval.nan, .infinity, -.infinity,
                    LeaseLimits.maximumDuration + 1] {
            assertLeaseError(
                { _ = try app.acquire(self.key, for: bad) },
                { if case .invalidDuration = $0 { return true } else { return false } },
                "duration \(bad) must be rejected"
            )
        }
        XCTAssertNil(store.snapshot[key])
    }

    func testTheDurationBoundsThemselvesAreAccepted() throws {
        let app = coordinator("app")
        XCTAssertNoThrow(try app.acquire(key, for: LeaseLimits.minimumDuration))
        XCTAssertNoThrow(try app.acquire(key, for: LeaseLimits.maximumDuration))
    }

    // MARK: - Clock skew

    func testAWallClockJumpingBackwardsDoesNotSurrenderALiveLease() throws {
        let app = coordinator("app")
        let widget = coordinator("widget")
        _ = try app.acquire(key, for: 60)

        // An NTP correction or the user editing the system date.
        clock.rewindWallClock(by: 3_600)

        assertLeaseError(
            { _ = try widget.acquire(self.key, for: 30) },
            { if case .heldByAnotherProcess = $0 { return true } else { return false } },
            "a backwards clock jump must not hand the lease to a peer"
        )
    }

    func testAWallClockJumpingForwardsExpiresALeaseEarlyWhichCostsLivenessNotSafety() throws {
        let app = coordinator("app")
        let widget = coordinator("widget")
        let original = try app.acquire(key, for: 3_600)

        // A forward jump does let a peer take over sooner than intended. That is
        // the acknowledged cost of a wall-clock deadline -- and the epoch bump is
        // what stops it from becoming data loss.
        clock.advance(by: 4_000)
        let stolen = try widget.acquire(key, for: 30)
        XCTAssertGreaterThan(stolen.token, original.token)
    }

    // MARK: - Store contention

    func testStoreContentionIsReportedSeparatelyFromLeaseContention() throws {
        let app = coordinator("app")
        store.simulateBusy(forNextCalls: 1)

        assertLeaseError(
            { _ = try app.acquire(self.key, for: 30) },
            { if case .storeBusy = $0 { return true } else { return false } },
            "critical-section contention is not the same as a held lease"
        )
        XCTAssertEqual(app.diagnostics.storeBusyRejections, 1)
        XCTAssertEqual(app.diagnostics.contentionRejections, 0)
        // Retryable, unlike a held lease.
        XCTAssertNoThrow(try app.acquire(key, for: 30))
    }

    // MARK: - Scoped helper

    func testWithLeaseReleasesEvenWhenTheBodyThrows() throws {
        let app = coordinator("app")
        struct Boom: Error {}

        XCTAssertThrowsError(
            try app.withLease(key, for: 3_600) { _ -> Int in throw Boom() }
        )
        // Released despite the throw, so a peer is not locked out for the full hour by
        // an error path.
        XCTAssertEqual(try app.isHeld(key), false)
        XCTAssertEqual(app.diagnostics.releases, 1)
    }

    func testWithLeaseReturnsTheBodyResultAndReleases() throws {
        let app = coordinator("app")
        let result = try app.withLease(key, for: 30) { lease in lease.token.rawValue }
        XCTAssertEqual(result, 1)
        XCTAssertEqual(try app.isHeld(key), false)
    }

    func testInspectDoesNotMutate() throws {
        let app = coordinator("app")
        XCTAssertNil(try app.inspect(key))
        let held = try app.acquire(key, for: 30)
        XCTAssertEqual(try app.inspect(key)?.token, held.token)
        XCTAssertEqual(try app.inspect(key)?.holder, app.processIdentity)
        XCTAssertEqual(try app.isHeld(key), true)
        XCTAssertEqual(app.diagnostics.acquisitions, 1)
    }

    func testRepeatedAcquireAndReleaseCyclesAdvanceTheEpochEveryTime() throws {
        let app = coordinator("app")
        var seen: [UInt64] = []
        for _ in 0..<10 {
            let lease = try app.acquire(key, for: 30)
            seen.append(lease.token.rawValue)
            try app.release(lease)
        }
        // Strictly increasing, with no repeats: the property, not a spot check.
        XCTAssertEqual(seen, Array(1...10))
        XCTAssertEqual(seen, seen.sorted())
        XCTAssertEqual(Set(seen).count, seen.count)
    }

    // MARK: - Concurrency

    func testConcurrentAcquisitionYieldsExactlyOneWinner() async throws {
        // Real contention: 32 threads, each with a distinct identity, all released from
        // a barrier so they hit the store at the same instant.
        //
        // The barrier is load-bearing. `acquire` is fully synchronous, so a task group
        // with no barrier lets the tasks run to completion one after another -- and a
        // version of this test without one passed roughly half the time against a store
        // whose lock had been deleted entirely, which makes it a coin toss rather than a
        // check. Its file-backed sibling
        // `testManyThreadsContendingThroughFlockProduceExactlyOneHolder` uses the same
        // pattern for the same reason.
        let contenders = 32
        let key = self.key!
        let clock = self.clock!
        let store = self.store!
        let winners = Collector<UInt64>()
        let readyGate = DispatchSemaphore(value: 0)
        let startGate = DispatchSemaphore(value: 0)
        let doneGate = DispatchSemaphore(value: 0)

        for index in 0..<contenders {
            let thread = Thread {
                let peer = LeaseCoordinator(
                    store: store,
                    identity: identity("peer-\(index)"),
                    clock: clock
                )
                readyGate.signal()
                startGate.wait()
                if let lease = try? peer.acquire(key, for: 3_600) {
                    winners.append(lease.token.rawValue)
                }
                doneGate.signal()
            }
            thread.name = "acquirer-\(index)"
            thread.start()
        }

        for _ in 0..<contenders {
            XCTAssertEqual(readyGate.wait(timeout: .now() + 30), .success)
        }
        for _ in 0..<contenders { startGate.signal() }
        for _ in 0..<contenders {
            XCTAssertEqual(doneGate.wait(timeout: .now() + 30), .success)
        }

        XCTAssertEqual(
            winners.count, 1,
            "exactly one peer may hold a live lease; winners: \(winners.elements)"
        )
        XCTAssertEqual(winners.elements, [1])
        XCTAssertEqual(store.snapshot[key]?.token, .initial)
    }

    func testReleasingAnAlreadyReleasedLeaseIsRefused() throws {
        // The tombstone must not be re-writable by a holder that has already let go.
        // Without the `!isReleased` guard this silently succeeds, re-stamping a
        // tombstone and inflating the release counter -- harmless today because the
        // token check blocks anything worse, but the guard is what keeps it that way.
        let app = coordinator("app")
        let held = try app.acquire(key, for: 30)
        try app.release(held)

        assertLeaseError(
            { try app.release(held) },
            { if case .notHolder = $0 { return true } else { return false } },
            "a second release must be refused"
        )
        XCTAssertEqual(app.diagnostics.releases, 1, "a refused release must not be counted")
        XCTAssertEqual(store.snapshot[key]?.isReleased, true)
        XCTAssertEqual(store.snapshot[key]?.token, held.token)
    }
}
