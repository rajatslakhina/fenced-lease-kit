import Foundation
import XCTest
@testable import FencedLease

private struct Payload: Codable, Sendable, Equatable {
    let writer: String
    let value: Int
}

/// Tests that go through the real filesystem and the real `flock` syscall.
///
/// `flock` is documented to treat separate file descriptors independently *even
/// within one process*: "An attempt to lock the file using one of these file
/// descriptors may be denied by a lock that the calling process has already
/// placed via another file descriptor." ``FileMutex`` opens a fresh descriptor per
/// entry, so two store instances here contend through the kernel exactly as two
/// separate processes would. That is what makes these tests real evidence about
/// cross-process behaviour rather than a simulation of it.
final class CrossProcessLeaseTests: XCTestCase {

    private var directory: TemporaryDirectory!
    private var leaseClock: ManualLeaseClock!
    private var key: LeaseKey!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try TemporaryDirectory()
        leaseClock = ManualLeaseClock(wallTime: Date(timeIntervalSince1970: 1_000))
        key = try requireKey("shared.digest")
    }

    override func tearDown() {
        directory = nil
        super.tearDown()
    }

    /// A store for one simulated process. The *mutex* budget runs on the real
    /// clock; only *lease expiry* is driven by the manual clock, so nothing here
    /// can spin waiting for a clock the test controls.
    private func makeStore() throws -> FileLeaseStore {
        try FileLeaseStore(
            directory: directory.url,
            acquisitionBudget: 0.05,
            clock: SystemLeaseClock()
        )
    }

    private func makeCoordinator(_ label: String) throws -> LeaseCoordinator {
        LeaseCoordinator(
            store: try makeStore(),
            identity: identity(label),
            clock: leaseClock
        )
    }

    // MARK: - Mutual exclusion across instances

    func testASecondProcessCannotTakeALiveLease() throws {
        let app = try makeCoordinator("app")
        let ext = try makeCoordinator("share-extension")

        _ = try app.acquire(key, for: 60)
        assertLeaseError(
            { _ = try ext.acquire(self.key, for: 60) },
            { if case .heldByAnotherProcess = $0 { return true } else { return false } },
            "a live lease must be visible to a separate store instance"
        )
    }

    func testTheRecordSurvivesAcrossStoreInstances() throws {
        let app = try makeCoordinator("app")
        let held = try app.acquire(key, for: 60)

        // A brand-new store instance, as a freshly launched extension would build.
        let observer = try makeCoordinator("widget")
        let seen = try observer.inspect(key)
        XCTAssertEqual(seen?.token, held.token)
        XCTAssertEqual(seen?.holder.label, "app")
    }

    func testExpiredLeaseIsStolenAtTheNextEpochOnDisk() throws {
        let app = try makeCoordinator("app")
        let ext = try makeCoordinator("share-extension")

        _ = try app.acquire(key, for: 30)
        leaseClock.advance(by: 31)
        let stolen = try ext.acquire(key, for: 30)

        XCTAssertEqual(stolen.token, FencingToken(rawValue: 2))
        // And it is durable, not just in memory.
        let reread = try makeCoordinator("observer").inspect(key)
        XCTAssertEqual(reread?.token, FencingToken(rawValue: 2))
        XCTAssertEqual(reread?.holder.label, "share-extension")
    }

    // MARK: - The headline scenario, end to end

    /// The whole point of the package, exercised through real files and real locks.
    func testSuspendedHolderIsFencedOutAfterAPeerTakesOver() throws {
        let app = try makeCoordinator("app")
        let ext = try makeCoordinator("share-extension")
        let storage = try FileFencedStorage(
            directory: directory.url,
            resourceName: key,
            clock: SystemLeaseClock()
        )
        let writer = FencedWriter<Payload>(storage: storage, clock: leaseClock)

        // 1. The app takes the lease and starts work.
        let appLease = try app.acquire(key, for: 30)

        // 2. The app is suspended. Wall time passes; its lease lapses.
        leaseClock.advance(by: 31)

        // 3. The extension reasonably concludes the app is gone and takes over.
        let extLease = try ext.acquire(key, for: 30)
        try writer.write(Payload(writer: "share-extension", value: 42), using: extLease)

        // 4. The app resumes, still holding a Lease handle it believes is valid,
        //    and tries to publish the result it computed before being stopped.
        assertLeaseError(
            { try writer.write(Payload(writer: "app", value: 7), using: appLease) },
            { if case .fenced = $0 { return true } else { return false } },
            "the resumed app must be fenced out"
        )

        // 5. The extension's value is intact. This is the data-loss bug that a
        //    deadline-only lock does not prevent.
        XCTAssertEqual(try writer.read(), Payload(writer: "share-extension", value: 42))
        XCTAssertEqual(writer.diagnostics.fencedWriteRejections, 1)
    }

    // MARK: - Critical-section contention

    func testAPeerStoppedInsideTheCriticalSectionReportsStoreBusyRatherThanBlocking() throws {
        let holder = try makeStore()
        let contender = try makeStore()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let key = self.key!

        // Occupy the critical section on another thread, modelling a peer that was
        // suspended mid-section.
        let worker = Thread {
            try? holder.withExclusiveAccess(to: key) { _ in
                entered.signal()
                release.wait()
                return (.leave, ())
            }
        }
        worker.start()
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)

        // A held section must cost the caller its budget and no more -- reported,
        // not blocked indefinitely. This is the property that makes using an OS
        // lock for the short section safe.
        let started = Date()
        assertLeaseError(
            { _ = try contender.withExclusiveAccess(to: key) { _ in (.leave, ()) } },
            { if case .storeBusy = $0 { return true } else { return false } },
            "contention on the critical section must be reported"
        )
        let elapsed = Date().timeIntervalSince(started)
        // The budget is 0.05s. Allowing 0.5s leaves an order of magnitude for CI
        // scheduling noise while still failing if the call actually blocked on the
        // peer instead of giving up -- the holder is parked indefinitely, so an
        // unbounded wait would hang here rather than finish slowly.
        XCTAssertLessThan(elapsed, 0.5, "the budget must bound the wait (was \(elapsed)s)")

        release.signal()
        // Once the section is free the contender succeeds, proving the failure was
        // contention and not a broken store.
        while !worker.isFinished { usleep(1_000) }
        XCTAssertNoThrow(try contender.withExclusiveAccess(to: key) { _ in (.leave, ()) })
    }

    // MARK: - Crash and corruption recovery

    func testAnEmptyLeaseRecordIsTreatedAsAbsentRatherThanBrickingTheKey() throws {
        let storage = try FileFencedStorage(
            directory: directory.url, resourceName: key, clock: SystemLeaseClock()
        )
        let writer = FencedWriter<Payload>(storage: storage, clock: leaseClock)
        let app = LeaseCoordinator(
            store: try makeStore(), identity: identity("app"),
            clock: leaseClock, epochFloor: writer
        )
        let stale = try app.acquire(key, for: 60)
        try writer.write(Payload(writer: "app", value: 1), using: stale)

        // The observable trace of a crash between `open` and `rename`.
        let recordURL = directory.url.appendingPathComponent("\(key.rawValue).lease.json")
        try Data().write(to: recordURL)

        // Refusing to proceed would turn a transient crash into a permanent outage on
        // this key.
        let fresh = LeaseCoordinator(
            store: try makeStore(), identity: identity("widget"),
            clock: leaseClock, epochFloor: writer
        )
        XCTAssertNil(try fresh.inspect(key))
        let recovered = try fresh.acquire(key, for: 60)

        // The part the name actually claims, and the part a weaker test would miss:
        // the new holder must be able to *write*. The epoch floor is what makes that
        // true -- without it the new epoch would be 1, below the resource's mark, and
        // the key would be permanently unusable.
        XCTAssertGreaterThan(recovered.token, stale.token)
        XCTAssertNoThrow(try writer.write(Payload(writer: "widget", value: 2), using: recovered))
        XCTAssertEqual(try writer.read(), Payload(writer: "widget", value: 2))
        // And the pre-crash holder is still fenced.
        assertLeaseError(
            { try writer.write(Payload(writer: "app", value: 9), using: stale) },
            { if case .fenced = $0 { return true } else { return false } },
            "losing the record must not re-admit the previous epoch"
        )
    }

    func testACorruptLeaseRecordIsTreatedAsAbsent() throws {
        let recordURL = directory.url.appendingPathComponent("\(key.rawValue).lease.json")
        try Data("{not json at all".utf8).write(to: recordURL)

        let app = try makeCoordinator("app")
        XCTAssertNil(try app.inspect(key))
        XCTAssertNoThrow(try app.acquire(key, for: 60))
    }

    func testALeaseRecordWrittenBeforeTombstonesExistedStillDecodes() throws {
        // Forward compatibility: `isReleased` was added after the first release, and a
        // record missing it must read as still-held rather than failing to decode and
        // being silently discarded -- which would reset the epoch sequence.
        let recordURL = directory.url.appendingPathComponent("\(key.rawValue).lease.json")
        let legacy = """
        {"acquiredAt":"2026-01-01T00:00:00Z","expiresAt":"2099-01-01T00:00:00Z",\
        "holder":{"label":"app","launchID":"\(UUID().uuidString)","processID":42},\
        "key":"\(key.rawValue)","token":{"rawValue":7}}
        """
        try Data(legacy.utf8).write(to: recordURL)

        let observer = try makeCoordinator("observer")
        let record = try observer.inspect(key)
        XCTAssertEqual(record?.token.rawValue, 7, "a legacy record must not be discarded")
        XCTAssertEqual(record?.isReleased, false)
        XCTAssertEqual(try observer.isHeld(key), true)
    }

    func testStagingFilesAreReapableAndLiveOnesAreLeftAlone() throws {
        let old = directory.url.appendingPathComponent("\(UUID().uuidString).tmp")
        let fresh = directory.url.appendingPathComponent("\(UUID().uuidString).tmp")
        let unrelated = directory.url.appendingPathComponent("keep.json")
        try Data("old".utf8).write(to: old)
        try Data("fresh".utf8).write(to: fresh)
        try Data("keep".utf8).write(to: unrelated)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path
        )

        let removed = AtomicFile.reapStagingFiles(in: directory.url, olderThan: 3_600)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        // A live writer's staging file must survive: there is no way to distinguish a
        // live one from an abandoned one except by age.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        // A malformed age is ignored rather than deleting everything.
        XCTAssertEqual(AtomicFile.reapStagingFiles(in: directory.url, olderThan: .nan), 0)
        XCTAssertEqual(AtomicFile.reapStagingFiles(in: directory.url, olderThan: -1), 0)
    }

    /// The asymmetry with the two tests above is deliberate and load-bearing.
    func testACorruptFencedEnvelopeFailsLoudlyInsteadOfResettingTheHighWaterMark() throws {
        let storage = try FileFencedStorage(
            directory: directory.url,
            resourceName: key,
            clock: SystemLeaseClock()
        )
        let writer = FencedWriter<Payload>(storage: storage, clock: leaseClock)
        let app = try makeCoordinator("app")
        let lease = try app.acquire(key, for: 60)
        try writer.write(Payload(writer: "app", value: 1), using: lease)

        let envelopeURL = directory.url.appendingPathComponent("\(key.rawValue).fenced.json")
        try Data("{corrupt".utf8).write(to: envelopeURL)

        // Treating this as absent would reset the high-water mark to nothing and
        // re-admit every superseded writer -- silently converting a corrupt file
        // into the exact data loss the fence exists to prevent. A lease record can
        // be discarded safely; the fence's memory cannot.
        assertLeaseError(
            { _ = try writer.read() },
            { if case .storageFailure = $0 { return true } else { return false } },
            "a corrupt envelope must not be silently discarded"
        )
    }

    func testWritesLeaveNoTemporaryFilesBehind() throws {
        let app = try makeCoordinator("app")
        let storage = try FileFencedStorage(
            directory: directory.url,
            resourceName: key,
            clock: SystemLeaseClock()
        )
        let writer = FencedWriter<Payload>(storage: storage, clock: leaseClock)

        for index in 0..<10 {
            let lease = try app.acquire(key, for: 60)
            try writer.write(Payload(writer: "app", value: index), using: lease)
        }

        let leftovers = directory.contents().filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "atomic rename must not leak staging files: \(leftovers)")
    }

    // MARK: - Real concurrency through the kernel

    func testManyThreadsContendingThroughFlockProduceExactlyOneHolder() throws {
        // Real OS-level contention: 16 threads, each with its own store instance and
        // therefore its own file descriptor, all racing for the same key.
        //
        // The barrier matters. Without it the threads can finish one after another,
        // and a test where the contenders never actually overlap would pass against
        // a store with no locking at all -- which would make this reassuring rather
        // than informative.
        let contenders = 16
        let key = self.key!
        let clock = leaseClock!
        let stores = try (0..<contenders).map { _ in try makeStore() }
        let winners = Collector<UInt64>()
        let readyGate = DispatchSemaphore(value: 0)
        let startGate = DispatchSemaphore(value: 0)
        let doneGate = DispatchSemaphore(value: 0)

        // Real `Thread`s rather than `DispatchQueue.global().async`. Every contender
        // parks on `startGate`, and GCD grows its pool lazily -- so 16 blocked
        // blocks on a 4-core runner take ten-plus seconds to even all start, which
        // makes the test slow and its margin against the timeout dependent on the
        // runner's core count. `Thread` starts immediately.
        for (index, store) in stores.enumerated() {
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
            thread.name = "contender-\(index)"
            thread.start()
        }

        // Every thread is running and parked before any of them touches the store.
        for _ in 0..<contenders {
            XCTAssertEqual(readyGate.wait(timeout: .now() + 30), .success)
        }
        for _ in 0..<contenders { startGate.signal() }
        for _ in 0..<contenders {
            XCTAssertEqual(doneGate.wait(timeout: .now() + 30), .success)
        }

        // Exactly one may win. A missing or non-atomic critical section shows up here
        // as several winners all holding epoch 1.
        XCTAssertEqual(
            winners.count, 1,
            "flock must serialise the read-modify-write; winners: \(winners.elements)"
        )
        XCTAssertEqual(winners.elements, [1])
        let record = try makeCoordinator("observer").inspect(key)
        XCTAssertEqual(record?.token, .initial)
    }
}

// MARK: - Shared conformance suite

/// Both ``LeaseStore`` implementations are held to the same contract, so the
/// in-memory fake used elsewhere in this suite cannot quietly become more
/// forgiving than the file-backed store that ships.
final class LeaseStoreConformanceTests: XCTestCase {

    /// Reads the record without mutating, via the store's only entry point.
    private func peek(_ store: any LeaseStore, _ key: LeaseKey) throws -> LeaseRecord? {
        try store.withExclusiveAccess(to: key) { (.leave, $0) }
    }

    private func runContract(
        _ store: any LeaseStore,
        _ key: LeaseKey,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let now = Date(timeIntervalSince1970: 5_000)
        let candidate = LeaseRecord(
            key: key,
            holder: identity("app"),
            token: .initial,
            acquiredAt: now,
            expiresAt: now.addingTimeInterval(60)
        )

        // 1. An untouched key reads as nil.
        XCTAssertNil(try peek(store, key), file: file, line: line)

        // 2. `.leave` must persist nothing.
        try store.withExclusiveAccess(to: key) { _ in (.leave, ()) }
        XCTAssertNil(try peek(store, key), file: file, line: line)

        // 3. `.store` persists and round-trips every field.
        try store.withExclusiveAccess(to: key) { _ in (.store(candidate), ()) }
        let stored = try peek(store, key)
        XCTAssertEqual(stored?.token, candidate.token, file: file, line: line)
        XCTAssertEqual(stored?.holder, candidate.holder, file: file, line: line)
        XCTAssertEqual(stored?.key, candidate.key, file: file, line: line)
        XCTAssertEqual(
            stored?.expiresAt.timeIntervalSince1970 ?? 0,
            candidate.expiresAt.timeIntervalSince1970,
            accuracy: 0.001,
            file: file, line: line
        )

        // 4. A throw from the body propagates and changes nothing.
        struct Boom: Error {}
        XCTAssertThrowsError(
            try store.withExclusiveAccess(to: key) { _ -> (LeaseMutation, Void) in throw Boom() },
            file: file, line: line
        )
        XCTAssertEqual(try peek(store, key)?.token, candidate.token, file: file, line: line)

        // 5. `.remove` deletes, and removing an absent record is not an error.
        try store.withExclusiveAccess(to: key) { _ in (.remove, ()) }
        XCTAssertNil(try peek(store, key), file: file, line: line)
        XCTAssertNoThrow(
            try store.withExclusiveAccess(to: key) { _ in (.remove, ()) },
            file: file, line: line
        )
    }

    func testInMemoryStoreSatisfiesTheContract() throws {
        try runContract(InMemoryLeaseStore(), try requireKey("contract"))
    }

    func testFileStoreSatisfiesTheSameContract() throws {
        let directory = try TemporaryDirectory()
        try runContract(
            try FileLeaseStore(directory: directory.url),
            try requireKey("contract")
        )
    }

    func testReEntryIsRefusedByBothStores() throws {
        // The protocol doc says a body must not call back into the store. The
        // in-memory fake previously used a plain recursive lock and allowed it, while
        // the file store threw -- the fake being more forgiving than the real thing.
        let directory = try TemporaryDirectory()
        let stores: [any LeaseStore] = [
            InMemoryLeaseStore(),
            try FileLeaseStore(directory: directory.url, acquisitionBudget: 0.02),
        ]
        let key = try requireKey("reentry")

        for store in stores {
            var inner: Error?
            try store.withExclusiveAccess(to: key) { _ in
                do {
                    _ = try store.withExclusiveAccess(to: key) { (.leave, $0) }
                } catch {
                    inner = error
                }
                return (.leave, ())
            }
            guard let error = inner as? LeaseError, case .storeBusy = error else {
                XCTFail("re-entry must throw storeBusy, got \(String(describing: inner))")
                continue
            }
        }
    }

    func testKeysAreIsolatedFromEachOtherInBothStores() throws {
        let directory = try TemporaryDirectory()
        let stores: [any LeaseStore] = [
            InMemoryLeaseStore(),
            try FileLeaseStore(directory: directory.url),
        ]
        let first = try requireKey("alpha")
        let second = try requireKey("beta")

        for store in stores {
            let record = LeaseRecord(
                key: first, holder: identity("app"), token: .initial,
                acquiredAt: Date(timeIntervalSince1970: 1), expiresAt: Date(timeIntervalSince1970: 61)
            )
            try store.withExclusiveAccess(to: first) { _ in (.store(record), ()) }
            XCTAssertNil(
                try peek(store, second),
                "one key's record must not be visible under another"
            )
            XCTAssertNotNil(try peek(store, first))
        }
    }
}
