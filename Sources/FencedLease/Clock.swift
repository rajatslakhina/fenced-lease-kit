import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - LeaseClock

/// The time source a lease is measured against.
///
/// This package deliberately exposes *two* readings, because a lease needs both
/// and they have different failure modes:
///
/// - ``wallTime`` is comparable across processes and survives process death, so
///   it is the only thing a *persisted* deadline can be expressed in. It can
///   also jump backwards or forwards at any moment (NTP steps, the user editing
///   the date, timezone-driven recalculation).
/// - ``monotonicNanoseconds`` never goes backwards, but its zero point is the
///   boot (or an arbitrary epoch), so it is meaningless to another process and
///   worthless after a restart. It is used only for *local* scheduling decisions
///   inside one process lifetime.
///
/// The consequence is stated once, here, because the whole design rests on it: a
/// persisted lease deadline is necessarily wall-clock, therefore a lease
/// deadline is necessarily untrustworthy, therefore mutual exclusion cannot be
/// built on the deadline alone. That is what ``FencingToken`` is for.
public protocol LeaseClock: Sendable {
    /// Wall-clock reading. Comparable across processes; may jump either way.
    var wallTime: Date { get }

    /// Monotonic reading in nanoseconds. Never decreases within one boot; not
    /// comparable across processes or across a reboot.
    var monotonicNanoseconds: UInt64 { get }
}

// MARK: - System clock

/// The production ``LeaseClock``, reading the host's real clocks.
public struct SystemLeaseClock: LeaseClock {

    public init() {}

    public var wallTime: Date { Date() }

    public var monotonicNanoseconds: UInt64 {
        var ts = timespec()
        // CLOCK_MONOTONIC is available on both Darwin and Glibc. A failure here
        // is not recoverable in any useful way, but it must not trap: falling
        // back to 0 makes monotonic-based *scheduling* degrade to "act now",
        // which is safe because nothing about correctness depends on this value.
        guard clock_gettime(CLOCK_MONOTONIC, &ts) == 0 else { return 0 }
        let seconds = UInt64(exactly: max(ts.tv_sec, 0)) ?? 0
        let nanos = UInt64(exactly: max(ts.tv_nsec, 0)) ?? 0
        let (scaled, secondsOverflowed) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !secondsOverflowed else { return UInt64.max }
        let (total, sumOverflowed) = scaled.addingReportingOverflow(nanos)
        return sumOverflowed ? UInt64.max : total
    }
}

// MARK: - Manual clock

/// A ``LeaseClock`` under the test's control.
///
/// Every time-dependent behaviour in this package -- expiry, stealing, renewal,
/// single-flight waiting -- is driven through this in tests. Nothing sleeps to
/// observe an expiry, and the pathological cases (a clock that runs backwards, a
/// process that resumes long after its lease lapsed) are reachable *by
/// construction* rather than by hoping the scheduler cooperates.
public final class ManualLeaseClock: LeaseClock, @unchecked Sendable {

    private let lock = NSLock()
    private var _wallTime: Date
    private var _monotonicNanoseconds: UInt64

    public init(wallTime: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self._wallTime = wallTime
        self._monotonicNanoseconds = 0
    }

    public var wallTime: Date {
        lock.lock()
        defer { lock.unlock() }
        return _wallTime
    }

    public var monotonicNanoseconds: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _monotonicNanoseconds
    }

    /// Advances both readings by `seconds`.
    ///
    /// Non-finite or non-positive input is ignored rather than trapping, so a
    /// malformed test parameter fails the assertion it was aimed at instead of
    /// crashing the whole suite.
    public func advance(by seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        _wallTime = _wallTime.addingTimeInterval(seconds)
        let delta = Saturating.nanoseconds(fromSeconds: seconds)
        let (sum, overflowed) = _monotonicNanoseconds.addingReportingOverflow(delta)
        _monotonicNanoseconds = overflowed ? UInt64.max : sum
    }

    /// Moves *only* the wall clock backwards, leaving the monotonic reading alone.
    ///
    /// This models the case the design has to survive: an NTP correction or a
    /// user editing the system date. It is deliberately impossible to move the
    /// monotonic reading backwards through this API, because a monotonic clock
    /// that goes backwards is not a thing the package is allowed to assume.
    public func rewindWallClock(by seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        _wallTime = _wallTime.addingTimeInterval(-seconds)
    }
}
