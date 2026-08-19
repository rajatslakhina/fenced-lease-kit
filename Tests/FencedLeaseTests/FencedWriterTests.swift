import Foundation
import XCTest
@testable import FencedLease

private struct Digest: Codable, Sendable, Equatable {
    let author: String
    let items: Int
}

final class FencedWriterTests: XCTestCase {

    private var store: InMemoryLeaseStore!
    private var storage: InMemoryFencedStorage!
    private var clock: ManualLeaseClock!
    private var key: LeaseKey!
    private var writer: FencedWriter<Digest>!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = InMemoryLeaseStore()
        storage = InMemoryFencedStorage()
        clock = ManualLeaseClock(wallTime: Date(timeIntervalSince1970: 1_000))
        key = try requireKey("feed.digest")
        writer = FencedWriter<Digest>(storage: storage, clock: clock)
    }

    private func coordinator(_ label: String) -> LeaseCoordinator {
        LeaseCoordinator(store: store, identity: identity(label), clock: clock)
    }

    // MARK: - Round trip

    func testWriteThenReadRoundTrips() throws {
        let lease = try coordinator("app").acquire(key, for: 30)
        try writer.write(Digest(author: "app", items: 3), using: lease)
        XCTAssertEqual(try writer.read(), Digest(author: "app", items: 3))
        XCTAssertEqual(try writer.highWaterMark(), .initial)
    }

    func testReadOnAnUntouchedResourceIsNilNotAnError() throws {
        XCTAssertNil(try writer.read())
        XCTAssertNil(try writer.highWaterMark())
        XCTAssertNil(try writer.readEnvelope())
    }

    func testTheSameEpochMayWriteRepeatedly() throws {
        let lease = try coordinator("app").acquire(key, for: 30)
        try writer.write(Digest(author: "app", items: 1), using: lease)
        try writer.write(Digest(author: "app", items: 2), using: lease)

        // Equality is accepted on purpose: a holder legitimately writes many times
        // within one epoch, and rejecting the second write would make the lease
        // useless.
        XCTAssertEqual(try writer.read(), Digest(author: "app", items: 2))
        XCTAssertEqual(writer.diagnostics.fencedWriteRejections, 0)
    }

    // MARK: - The fence

    func testASupersededWriterIsRejectedAndTheNewerValueSurvives() throws {
        let app = coordinator("app")
        let widget = coordinator("widget")

        let stale = try app.acquire(key, for: 30)
        clock.advance(by: 31)
        let current = try widget.acquire(key, for: 30)

        try writer.write(Digest(author: "widget", items: 99), using: current)

        assertLeaseError(
            { try self.writer.write(Digest(author: "app", items: 1), using: stale) },
            { error in
                if case let .fenced(presented, highWaterMark) = error {
                    return presented == stale.token && highWaterMark == current.token
                }
                return false
            },
            "a superseded epoch must not be able to write"
        )

        // The assertion that actually matters: the rejection preserved the newer
        // value rather than merely returning an error after clobbering it.
        XCTAssertEqual(try writer.read(), Digest(author: "widget", items: 99))
        XCTAssertEqual(try writer.highWaterMark(), current.token)
        XCTAssertEqual(writer.diagnostics.fencedWriteRejections, 1)
    }

    /// Runs the identical scenario through a writer with no fence, and asserts the
    /// value **is** destroyed.
    ///
    /// This is what makes the test above evidence rather than decoration: it shows
    /// the scenario really does end in data loss when the check is absent, so a
    /// passing fence test cannot be a false positive.
    func testWithoutTheFenceTheSupersededWriterDestroysTheNewerValue() throws {
        let app = coordinator("app")
        let widget = coordinator("widget")
        let unfenced = UnfencedWriterForTesting<Digest>(storage: storage)

        let stale = try app.acquire(key, for: 30)
        clock.advance(by: 31)
        let current = try widget.acquire(key, for: 30)

        try unfenced.write(Digest(author: "widget", items: 99), using: current)
        try unfenced.write(Digest(author: "app", items: 1), using: stale)

        // Last-writer-wins: the stale process, resuming from suspension, silently
        // overwrote the value its successor had already published.
        XCTAssertEqual(try writer.read(), Digest(author: "app", items: 1))
        // And it walked the high-water mark backwards, re-admitting every epoch
        // between the two.
        XCTAssertEqual(try writer.highWaterMark(), stale.token)
    }

    func testANewerEpochOverwritesFreely() throws {
        let app = coordinator("app")
        let widget = coordinator("widget")

        let first = try app.acquire(key, for: 30)
        try writer.write(Digest(author: "app", items: 1), using: first)

        clock.advance(by: 31)
        let second = try widget.acquire(key, for: 30)
        try writer.write(Digest(author: "widget", items: 2), using: second)

        XCTAssertEqual(try writer.read(), Digest(author: "widget", items: 2))
        XCTAssertEqual(try writer.highWaterMark(), second.token)
    }

    /// The subtle half of the design: the writer never consults the deadline.
    func testAnExpiredButUnsupersededLeaseMayStillWrite() throws {
        let app = coordinator("app")
        let lease = try app.acquire(key, for: 30)

        clock.advance(by: 500)

        // The lease has lapsed, but nobody took over, so the high-water mark is
        // still this holder's epoch and there is nothing to clobber. Rejecting here
        // would make the writer stricter than correctness requires -- and would
        // make every write racy against a clock the package already admits it
        // cannot trust.
        XCTAssertNoThrow(try writer.write(Digest(author: "app", items: 7), using: lease))
        XCTAssertEqual(try writer.read(), Digest(author: "app", items: 7))
    }

    func testTheFenceNeedsNoClockAtAll() throws {
        // Same scenario as the rejection test, but the clock is rewound to before
        // the stale lease was even granted. The outcome is identical, because the
        // decision is made on epochs, not instants.
        let app = coordinator("app")
        let widget = coordinator("widget")

        let stale = try app.acquire(key, for: 30)
        clock.advance(by: 31)
        let current = try widget.acquire(key, for: 30)
        try writer.write(Digest(author: "widget", items: 99), using: current)

        clock.rewindWallClock(by: 10_000)

        assertLeaseError(
            { try self.writer.write(Digest(author: "app", items: 1), using: stale) },
            { if case .fenced = $0 { return true } else { return false } },
            "the fence must not depend on the clock"
        )
        XCTAssertEqual(try writer.read(), Digest(author: "widget", items: 99))
    }

    // MARK: - Provenance

    func testEnvelopeCarriesWriterProvenance() throws {
        let lease = try coordinator("share-extension").acquire(key, for: 30)
        try writer.write(Digest(author: "ext", items: 4), using: lease)

        let readBack = try writer.readEnvelope()
        XCTAssertEqual(readBack?.envelope.writerLabel, "share-extension")
        XCTAssertEqual(readBack?.envelope.writtenAt, clock.wallTime)
        XCTAssertEqual(readBack?.value, Digest(author: "ext", items: 4))
    }

    // MARK: - Concurrency

    func testTheHighWaterMarkNeverDecreasesUnderConcurrentWritesFromManyEpochs() async throws {
        // The property under test is *monotonicity of the observed mark over time*, and
        // asserting it requires an observer that samples in order. A previous version of
        // this test collected samples from the writer tasks themselves and asserted
        // `sample <= max(allTokens)` -- which is true by construction and holds with the
        // fence deleted entirely. This version has a single dedicated observer thread,
        // so the sample sequence is genuinely ordered and a mark that went backwards
        // would be caught.
        let app = coordinator("app")
        var leases: [Lease] = []
        for _ in 0..<8 {
            let lease = try app.acquire(key, for: 1)
            leases.append(lease)
            clock.advance(by: 2)
        }
        let highest = leases.map(\.token.rawValue).max() ?? 0
        let writer = self.writer!
        let storage = self.storage!
        let samples = Collector<UInt64>()
        let stop = ManagedAtomicFlag()

        let observer = Thread {
            while !stop.isSet {
                if let mark = storage.snapshot?.acceptedToken.rawValue {
                    samples.append(mark)
                }
            }
            // One final read after the writers are done.
            if let mark = storage.snapshot?.acceptedToken.rawValue {
                samples.append(mark)
            }
        }
        observer.start()

        let rejected = Collector<Bool>()
        await withTaskGroup(of: Void.self) { group in
            for lease in leases.shuffled() {
                group.addTask {
                    do {
                        try writer.write(
                            Digest(author: lease.holder.label, items: 1), using: lease
                        )
                        rejected.append(false)
                    } catch {
                        rejected.append(true)
                    }
                }
            }
        }
        stop.set()
        while !observer.isFinished { usleep(1_000) }

        // 1. The ordered sample sequence never decreases. This is the assertion the
        //    test is named for, and it fails if a stale write is ever accepted.
        let observed = samples.elements
        XCTAssertFalse(observed.isEmpty, "the observer must have sampled something")
        for (previous, next) in zip(observed, observed.dropFirst()) {
            XCTAssertLessThanOrEqual(
                previous, next,
                "the high-water mark went backwards: \(previous) then \(next)"
            )
        }

        // 2. It ends at the highest epoch that participated.
        XCTAssertEqual(try writer.highWaterMark()?.rawValue, highest)

        // 3. Every write either landed or was counted as fenced -- no silent drops.
        XCTAssertEqual(rejected.elements.count, leases.count)
        XCTAssertEqual(
            writer.diagnostics.fencedWriteRejections,
            rejected.elements.filter { $0 }.count,
            "every rejection must be counted"
        )
        // 4. And at least one was genuinely rejected: with 8 distinct epochs written in
        //    a shuffled order, the last-written epoch cannot be the highest every time,
        //    so a run where nothing is fenced means the fence is not running.
        XCTAssertGreaterThan(
            writer.diagnostics.fencedWriteRejections, 0,
            "8 shuffled epochs must produce at least one fenced write"
        )
    }
}

/// A minimal set-once flag usable from a `Thread` body.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }
}

// MARK: - FencedStorage conformance

/// Both ``FencedStorage`` implementations against one contract, for the same reason
/// ``LeaseStore`` has one: the in-memory fake must not be more forgiving than the
/// file-backed store it stands in for.
final class FencedStorageConformanceTests: XCTestCase {

    private func envelope(_ token: UInt64, _ payload: String) -> FencedEnvelope {
        FencedEnvelope(
            acceptedToken: FencingToken(rawValue: token),
            payload: Data(payload.utf8),
            writtenAt: Date(timeIntervalSince1970: 1_000),
            writerLabel: "test"
        )
    }

    private func peek(_ storage: any FencedStorage) throws -> FencedEnvelope? {
        try storage.withExclusiveAccess { (nil, $0) }
    }

    private func runContract(
        _ storage: any FencedStorage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // 1. Untouched reads as nil.
        XCTAssertNil(try peek(storage), file: file, line: line)

        // 2. Returning nil writes nothing.
        try storage.withExclusiveAccess { _ in (nil, ()) }
        XCTAssertNil(try peek(storage), file: file, line: line)

        // 3. Writing round-trips every field.
        let first = envelope(1, "one")
        try storage.withExclusiveAccess { _ in (first, ()) }
        let stored = try peek(storage)
        XCTAssertEqual(stored?.acceptedToken, first.acceptedToken, file: file, line: line)
        XCTAssertEqual(stored?.payload, first.payload, file: file, line: line)
        XCTAssertEqual(stored?.writerLabel, first.writerLabel, file: file, line: line)
        XCTAssertEqual(
            stored?.writtenAt.timeIntervalSince1970 ?? 0,
            first.writtenAt.timeIntervalSince1970,
            accuracy: 0.001, file: file, line: line
        )

        // 4. A throw propagates and changes nothing.
        struct Boom: Error {}
        XCTAssertThrowsError(
            try storage.withExclusiveAccess { _ -> (FencedEnvelope?, Void) in throw Boom() },
            file: file, line: line
        )
        XCTAssertEqual(try peek(storage)?.payload, first.payload, file: file, line: line)

        // 5. Re-entry from the same thread is refused, not silently allowed. The fake
        //    used to permit it via a recursive lock while the real store threw, which
        //    is exactly the drift this suite exists to catch.
        var innerError: Error?
        try storage.withExclusiveAccess { _ in
            do {
                _ = try self.peek(storage)
            } catch {
                innerError = error
            }
            return (nil, ())
        }
        guard let innerError = innerError as? LeaseError else {
            XCTFail("re-entry must throw a LeaseError", file: file, line: line)
            return
        }
        guard case .storeBusy = innerError else {
            XCTFail("re-entry must throw storeBusy, got \(innerError)", file: file, line: line)
            return
        }
    }

    func testInMemoryStorageSatisfiesTheContract() throws {
        try runContract(InMemoryFencedStorage())
    }

    func testFileStorageSatisfiesTheSameContract() throws {
        let directory = try TemporaryDirectory()
        try runContract(
            try FileFencedStorage(
                directory: directory.url,
                resourceName: try requireKey("contract")
            )
        )
    }

    func testAtomicityIsRequiredForTheFenceToBeAFence() throws {
        // The fence is a read-compare-write. If the storage did not serialise it, two
        // writers could both read the same mark and both pass the comparison. This
        // asserts the storage genuinely holds the section across the body, which is
        // the property `FencedWriter` relies on.
        let storage = InMemoryFencedStorage()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let secondSawFirstWrite = Collector<Bool>()
        // Built outside the closure so the thread body captures a value rather than
        // the (non-Sendable) test case.
        let toWrite = envelope(5, "five")

        let holder = Thread {
            try? storage.withExclusiveAccess { _ in
                entered.signal()
                release.wait()
                return (toWrite, ())
            }
        }
        holder.start()
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)

        let contender = Thread {
            // Blocks until the holder's body completes and its write lands.
            let seen = (try? storage.withExclusiveAccess { (nil, $0) })??.acceptedToken
            secondSawFirstWrite.append(seen == FencingToken(rawValue: 5))
            secondFinished.signal()
        }
        contender.start()
        // Give the contender time to be genuinely blocked rather than merely queued.
        Thread.sleep(forTimeInterval: 0.05)
        release.signal()
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(
            secondSawFirstWrite.elements, [true],
            "a second thread must not enter until the first body's write has landed"
        )
    }
}
