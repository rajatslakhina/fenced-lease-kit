import Foundation
import XCTest
@testable import FencedLease

final class FencingTokenTests: XCTestCase {

    func testInitialTokenIsOneSoZeroCanMeanNeverWritten() {
        XCTAssertEqual(FencingToken.initial.rawValue, 1)
    }

    func testNextIncrementsByExactlyOne() throws {
        XCTAssertEqual(try FencingToken(rawValue: 41).next().rawValue, 42)
    }

    func testNextThrowsAtTheCeilingRatherThanWrapping() {
        // Wrapping here would hand a new epoch a token *below* the resource's
        // high-water mark, silently inverting the package's safety property.
        assertLeaseError(
            { _ = try FencingToken(rawValue: UInt64.max).next() },
            { $0 == .tokenSpaceExhausted },
            "token space exhaustion must be reported, not wrapped"
        )
    }

    func testOrderingFollowsRawValue() {
        XCTAssertLessThan(FencingToken(rawValue: 1), FencingToken(rawValue: 2))
        XCTAssertFalse(FencingToken(rawValue: 2) < FencingToken(rawValue: 2))
    }
}

final class LeaseKeyTests: XCTestCase {

    func testAcceptsOrdinaryNames() {
        XCTAssertNotNil(LeaseKey("feed.digest"))
        XCTAssertNotNil(LeaseKey("shared_index-v2"))
        XCTAssertNotNil(LeaseKey("a"))
    }

    func testRejectsEmptyAndOverlongNames() {
        XCTAssertNil(LeaseKey(""))
        XCTAssertNil(LeaseKey(String(repeating: "a", count: LeaseKey.maximumLength + 1)))
        XCTAssertNotNil(LeaseKey(String(repeating: "a", count: LeaseKey.maximumLength)))
    }

    func testRejectsPathTraversal() {
        // The store interpolates the raw value straight into a filename, so these
        // are the cases that would let a caller write outside the App Group
        // container.
        for candidate in ["..", ".", "...", "../etc/passwd", "a/b", "a\\b", "~", "a b", "a\0b"] {
            XCTAssertNil(LeaseKey(candidate), "\"\(candidate)\" must be rejected")
        }
    }

    func testDecodingRejectsAnInvalidRawValue() throws {
        // A key that got onto disk through some other route must not be trusted
        // back into memory just because it decodes as a String.
        let payload = Data(#""../escape""#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LeaseKey.self, from: payload))
    }

    func testCodableRoundTrip() throws {
        let key = try requireKey("feed.digest")
        let data = try JSONEncoder().encode(key)
        XCTAssertEqual(try JSONDecoder().decode(LeaseKey.self, from: data), key)
    }

    // MARK: - The total initialiser

    func testSanitisingInitialiserIsTotalAcrossEveryInputTheStrictOneRejects() {
        // Every one of these returns nil from `init(_:)`. `init(sanitising:)` must
        // produce a usable key for all of them, since its whole purpose is to let a
        // call site hold a key without a `!` or an optional.
        let hostile = [
            "", "..", ".", "...", "../etc/passwd", "a/b", "a\\b", "~", "a b", "a\0b",
            String(repeating: "z", count: LeaseKey.maximumLength + 500),
            "\u{1F600}\u{1F600}",
        ]
        for input in hostile {
            let key = LeaseKey(sanitising: input)
            XCTAssertFalse(key.rawValue.isEmpty, "\"\(input)\" produced an empty key")
            XCTAssertLessThanOrEqual(key.rawValue.count, LeaseKey.maximumLength)
            // The decisive check: the sanitised output must itself pass the strict
            // validator. If it did not, the "total" initialiser would be handing out
            // keys the file store considers unsafe.
            XCTAssertNotNil(
                LeaseKey(key.rawValue),
                "sanitising \"\(input)\" produced \"\(key.rawValue)\", which the strict "
                + "initialiser rejects"
            )
        }
    }

    func testSanitisingLeavesAValidNameUntouched() {
        XCTAssertEqual(LeaseKey(sanitising: "shared.digest").rawValue, "shared.digest")
        XCTAssertEqual(LeaseKey(sanitising: "a_b-c.1").rawValue, "a_b-c.1")
    }

    func testSanitisingReplacesRatherThanDroppingSoDistinctNamesStayDistinct() {
        // Dropping bad characters would collapse "a/b" and "ab" onto the same key,
        // silently merging two resources. Replacement keeps them apart.
        XCTAssertEqual(LeaseKey(sanitising: "a/b").rawValue, "a-b")
        XCTAssertNotEqual(
            LeaseKey(sanitising: "a/b").rawValue,
            LeaseKey(sanitising: "ab").rawValue
        )
    }

    func testSanitisingFallbackNameIsItselfValid() {
        XCTAssertNotNil(LeaseKey(LeaseKey.fallbackName))
        XCTAssertEqual(LeaseKey(sanitising: "").rawValue, LeaseKey.fallbackName)
    }
}

final class LeaseRecordTests: XCTestCase {

    func testExpiryBoundaryIsInclusive() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let record = LeaseRecord(
            key: try requireKey("k"),
            holder: identity("app"),
            token: .initial,
            acquiredAt: start,
            expiresAt: start.addingTimeInterval(10)
        )
        XCTAssertFalse(record.isExpired(at: start.addingTimeInterval(9.999)))
        // Inclusive on purpose: two processes reading the identical instant must
        // never both conclude the lease is live.
        XCTAssertTrue(record.isExpired(at: start.addingTimeInterval(10)))
        XCTAssertTrue(record.isExpired(at: start.addingTimeInterval(10.001)))
    }

    func testRenewalPreservesTheEpoch() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let record = LeaseRecord(
            key: try requireKey("k"),
            holder: identity("app"),
            token: FencingToken(rawValue: 7),
            acquiredAt: start,
            expiresAt: start.addingTimeInterval(5)
        )
        let renewed = record.renewed(until: start.addingTimeInterval(50))
        XCTAssertEqual(renewed.token, FencingToken(rawValue: 7))
        XCTAssertEqual(renewed.acquiredAt, start)
        XCTAssertEqual(renewed.expiresAt, start.addingTimeInterval(50))
    }
}

final class ProcessIdentityTests: XCTestCase {

    func testSamePIDWithDifferentLaunchIDsAreDifferentProcesses() {
        // The kernel recycles PIDs, and iOS extension launches cycle through the
        // same small numbers quickly. If identity were the PID alone, a fresh
        // process could read "held by pid 431" and conclude it held the lease.
        let first = ProcessIdentity(processID: 431, launchID: UUID(), label: "share-extension")
        let second = ProcessIdentity(processID: 431, launchID: UUID(), label: "share-extension")
        XCTAssertNotEqual(first, second)
    }

    func testCurrentIsStableWithinOneProcess() {
        XCTAssertEqual(
            ProcessIdentity.current(label: "app").launchID,
            ProcessIdentity.current(label: "widget").launchID
        )
    }

    /// The hazard `current(label:)` documents, pinned so it stays a known property.
    func testTwoCoordinatorsSharingAnIdentityShareAnEpoch() throws {
        // A lease coordinates *processes*. Two coordinators built with the same label in
        // one process are the same identity, so the second acquire takes the renewal
        // path and is handed the first's live epoch. This is asserted rather than
        // treated as a bug, because the alternative -- making identity per-instance by
        // default -- would stop a legitimately restarted coordinator in the same
        // process from renewing its own lease.
        let store = InMemoryLeaseStore()
        let clock = ManualLeaseClock()
        let key = try requireKey("shared")
        let first = LeaseCoordinator(
            store: store, identity: .current(label: "app"), clock: clock
        )
        let second = LeaseCoordinator(
            store: store, identity: .current(label: "app"), clock: clock
        )

        let a = try first.acquire(key, for: 3_600)
        let b = try second.acquire(key, for: 3_600)
        XCTAssertEqual(a.token, b.token, "same identity means same epoch, not contention")
        XCTAssertEqual(second.diagnostics.renewals, 1)
        XCTAssertEqual(second.diagnostics.contentionRejections, 0)
    }

    /// And the documented escape hatch genuinely produces contention.
    func testDistinctIdentitiesContendProperly() throws {
        let store = InMemoryLeaseStore()
        let clock = ManualLeaseClock()
        let key = try requireKey("shared")
        let first = LeaseCoordinator(
            store: store, identity: .distinct(label: "app"), clock: clock
        )
        let second = LeaseCoordinator(
            store: store, identity: .distinct(label: "app"), clock: clock
        )

        _ = try first.acquire(key, for: 3_600)
        assertLeaseError(
            { _ = try second.acquire(key, for: 3_600) },
            { if case .heldByAnotherProcess = $0 { return true } else { return false } },
            "distinct identities must contend"
        )
        XCTAssertNotEqual(
            ProcessIdentity.distinct(label: "x"), ProcessIdentity.distinct(label: "x")
        )
    }
}

final class ArithmeticTests: XCTestCase {

    func testAddSaturatesAtBothBounds() {
        XCTAssertEqual(Saturating.add(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.add(Int.max - 2, 5), Int.max)
        XCTAssertEqual(Saturating.add(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.add(7, 5), 12)
    }

    func testIncrementSaturates() {
        XCTAssertEqual(Saturating.increment(Int.max), Int.max)
        XCTAssertEqual(Saturating.increment(0), 1)
    }

    func testNanosecondsHandlesEveryTrappingInput() {
        // Each of these traps under a plain `UInt64(seconds * 1e9)`.
        XCTAssertEqual(Saturating.nanoseconds(fromSeconds: .nan), 0)
        XCTAssertEqual(Saturating.nanoseconds(fromSeconds: -.infinity), 0)
        XCTAssertEqual(Saturating.nanoseconds(fromSeconds: -1), 0)
        XCTAssertEqual(Saturating.nanoseconds(fromSeconds: 0), 0)
        XCTAssertEqual(Saturating.nanoseconds(fromSeconds: 0.25), 250_000_000)

        // Non-finite maps to 0 ("not a usable duration, do not wait") rather than
        // to the ceiling ("wait approximately forever"), because every caller
        // spends this as a wait budget and an unbounded wait reached through a bad
        // config value is the deadlock the package exists to avoid.
        XCTAssertEqual(Saturating.nanoseconds(fromSeconds: .infinity), 0)

        // A large *finite* value is a different intent -- the caller meant a long
        // wait -- so it clamps rather than being discarded.
        XCTAssertEqual(Saturating.nanoseconds(fromSeconds: 1e30), UInt64.max)
    }

    func testIntConversionHandlesEveryTrappingInput() {
        // Each of these traps under a plain `Int(value)`.
        XCTAssertEqual(Saturating.int(from: .nan, clampedTo: 3...9), 3)
        XCTAssertEqual(Saturating.int(from: .infinity, clampedTo: 3...9), 9)
        XCTAssertEqual(Saturating.int(from: -.infinity, clampedTo: 3...9), 3)
        XCTAssertEqual(Saturating.int(from: 1e300, clampedTo: 0...10_000), 10_000)
        XCTAssertEqual(Saturating.int(from: 5.7, clampedTo: 0...10), 5)
    }

    func testIntConversionIsSafeAtTheFullIntRange() {
        // The boundary the implementation's doc comment agonises over, and the one
        // where a naive `Int(value)` after a `<=`/`>=` comparison can still trap:
        // `Double(Int.max)` rounds *up* to exactly 2^63, which is not representable
        // as an Int. The `>=` test has to catch that before the conversion.
        let full = Int.min...Int.max
        XCTAssertEqual(Saturating.int(from: .nan, clampedTo: full), Int.min)
        XCTAssertEqual(Saturating.int(from: .infinity, clampedTo: full), Int.max)
        XCTAssertEqual(Saturating.int(from: -.infinity, clampedTo: full), Int.min)
        XCTAssertEqual(Saturating.int(from: Double(Int.max), clampedTo: full), Int.max)
        XCTAssertEqual(Saturating.int(from: Double(Int.min), clampedTo: full), Int.min)
        XCTAssertEqual(Saturating.int(from: 1e300, clampedTo: full), Int.max)
        XCTAssertEqual(Saturating.int(from: -1e300, clampedTo: full), Int.min)
        XCTAssertEqual(Saturating.int(from: 0, clampedTo: full), 0)
        XCTAssertEqual(Saturating.int(from: -7.9, clampedTo: full), -7)
    }

    func testNanosecondsIsSafeAtTheFullUInt64Range() {
        // Same rounding hazard on the unsigned side: `Double(UInt64.max)` is exactly
        // 2^64, which is not representable as a UInt64.
        XCTAssertEqual(Saturating.nanoseconds(fromSeconds: Double(UInt64.max)), UInt64.max)
        XCTAssertEqual(
            Saturating.nanoseconds(fromSeconds: Double(UInt64.max) / 1_000_000_000),
            UInt64.max
        )
    }

    func testClampResolvesNaNToTheLowerBound() {
        // `min(max(x, lo), hi)` silently propagates NaN; this must not.
        XCTAssertEqual(Saturating.clamp(.nan, to: 1...2), 1)
        XCTAssertEqual(Saturating.clamp(5, to: 1...2), 2)
        XCTAssertEqual(Saturating.clamp(0, to: 1...2), 1)
        XCTAssertEqual(Saturating.clamp(1.5, to: 1...2), 1.5)
    }
}

final class ClockTests: XCTestCase {

    func testManualClockAdvancesBothReadings() {
        let clock = ManualLeaseClock(wallTime: Date(timeIntervalSince1970: 100))
        let startMonotonic = clock.monotonicNanoseconds
        clock.advance(by: 2)
        XCTAssertEqual(clock.wallTime, Date(timeIntervalSince1970: 102))
        XCTAssertEqual(clock.monotonicNanoseconds, startMonotonic + 2_000_000_000)
    }

    func testRewindMovesOnlyTheWallClock() {
        let clock = ManualLeaseClock(wallTime: Date(timeIntervalSince1970: 100))
        clock.advance(by: 10)
        let monotonicBefore = clock.monotonicNanoseconds
        clock.rewindWallClock(by: 30)
        XCTAssertEqual(clock.wallTime, Date(timeIntervalSince1970: 80))
        // A monotonic clock that goes backwards is not something the package is
        // allowed to assume, so the API cannot express it.
        XCTAssertEqual(clock.monotonicNanoseconds, monotonicBefore)
    }

    func testMalformedAdvanceIsIgnoredRatherThanTrapping() {
        let clock = ManualLeaseClock(wallTime: Date(timeIntervalSince1970: 100))
        clock.advance(by: .nan)
        clock.advance(by: -5)
        clock.advance(by: .infinity)
        XCTAssertEqual(clock.wallTime, Date(timeIntervalSince1970: 100))
    }

    func testSystemMonotonicClockAdvancesAcrossAKnownSleep() {
        // Asserting only "two consecutive readings do not decrease" would pass against
        // a stub returning a constant. Sleeping a known interval and requiring the
        // reading to have advanced by at least most of it makes the test detect a
        // clock that is not actually running, while staying insensitive to scheduling
        // overshoot (which can only make the delta larger).
        let clock = SystemLeaseClock()
        let before = clock.monotonicNanoseconds
        Thread.sleep(forTimeInterval: 0.05)
        let after = clock.monotonicNanoseconds

        XCTAssertGreaterThan(before, 0)
        // Subtracting UInt64s directly would trap if `after < before` -- which can only
        // happen if `clock_gettime` failed on the second read and returned 0. Assert
        // the ordering first so a clock fault fails the test instead of crashing the
        // whole suite.
        XCTAssertGreaterThanOrEqual(after, before)
        let delta = after >= before ? after - before : 0
        XCTAssertGreaterThanOrEqual(
            delta, 40_000_000,
            "the monotonic clock did not advance across a 50ms sleep"
        )
    }

    func testSystemWallClockTracksDate() {
        let clock = SystemLeaseClock()
        XCTAssertEqual(
            clock.wallTime.timeIntervalSince1970,
            Date().timeIntervalSince1970,
            accuracy: 5
        )
    }
}
