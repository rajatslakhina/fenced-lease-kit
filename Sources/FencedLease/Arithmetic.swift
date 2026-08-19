import Foundation

// MARK: - Saturating arithmetic

/// Arithmetic helpers that saturate instead of trapping.
///
/// Every counter in this package is a diagnostic, never a control value. A
/// diagnostic that crashes the app it is observing is worse than a diagnostic
/// that goes slightly wrong, so these saturate at the representable bound
/// rather than overflowing.
///
/// The ceilings are derived from `Int.max` / `UInt64.max` rather than written as
/// 64-bit literals, because `Int` is 32-bit on some Apple platforms and a
/// hardcoded `9_223_372_036_854_775_807` would be a silent compile error there.
public enum Saturating {

    /// `value + increment`, clamped to `Int.max` and `Int.min`.
    @inlinable
    public static func add(_ value: Int, _ increment: Int) -> Int {
        let (sum, overflowed) = value.addingReportingOverflow(increment)
        if overflowed {
            return increment >= 0 ? Int.max : Int.min
        }
        return sum
    }

    /// `value + 1`, clamped to `Int.max`.
    @inlinable
    public static func increment(_ value: Int) -> Int {
        add(value, 1)
    }

    /// Converts a duration in seconds to whole nanoseconds without trapping.
    ///
    /// `UInt64(someDouble)` traps on NaN, on infinity, and on any value outside
    /// `UInt64`'s representable range. Sleeps and budgets in this package are
    /// driven by durations that originate in configuration, so a malformed
    /// configuration value must degrade rather than crash.
    ///
    /// - Returns: `0` for NaN, infinity, negative, or zero input; `UInt64.max` for
    ///   a large but *finite* input that would overflow; otherwise the truncated
    ///   nanosecond count.
    ///
    ///   Mapping non-finite input to `0` rather than to `UInt64.max` is
    ///   deliberate. Every caller here uses the result as a wait or a retry
    ///   budget, so `0` means "this is not a usable duration, do not wait" while
    ///   `UInt64.max` would mean "wait approximately forever" -- and an unbounded
    ///   wait reached through a bad config value is precisely the deadlock this
    ///   package is built to avoid. A large finite value is a different case: the
    ///   caller meant a long wait, so it is clamped rather than discarded.
    @inlinable
    public static func nanoseconds(fromSeconds seconds: Double) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let nanos = seconds * 1_000_000_000
        // Compare against the Double representation of UInt64.max before
        // converting. `nanos >= 2^64` is the trapping case.
        guard nanos < Double(UInt64.max) else { return UInt64.max }
        return UInt64(nanos)
    }

    /// Converts a `Double` to an `Int` clamped into `range`, without trapping.
    ///
    /// `Int(someDouble)` traps on NaN, on infinity, and on anything outside
    /// `Int`'s range -- and `Int` is 32-bit on some Apple platforms, so the
    /// out-of-range case is far closer than a 64-bit intuition suggests. The
    /// range bound is what makes this total; NaN resolves to `range.lowerBound`.
    @inlinable
    public static func int(from value: Double, clampedTo range: ClosedRange<Int>) -> Int {
        guard !value.isNaN else { return range.lowerBound }
        if value <= Double(range.lowerBound) { return range.lowerBound }
        if value >= Double(range.upperBound) { return range.upperBound }
        // Now provably inside the representable range, so this cannot trap.
        return Int(value)
    }

    /// Clamps a `Double` to a closed range, mapping NaN to the lower bound.
    ///
    /// NaN compares `false` against everything, so a naive `min(max(x, lo), hi)`
    /// silently propagates it. Callers here use the result to size buffers and
    /// deadlines, so NaN is resolved explicitly.
    @inlinable
    public static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard !value.isNaN else { return range.lowerBound }
        if value < range.lowerBound { return range.lowerBound }
        if value > range.upperBound { return range.upperBound }
        return value
    }
}
