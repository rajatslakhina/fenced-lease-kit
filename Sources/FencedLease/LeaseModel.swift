import Foundation

// MARK: - LeaseKey

/// Names the resource a lease protects.
///
/// The raw value is validated on construction because a ``FileLeaseStore``
/// derives a filename from it. An unvalidated key containing `../` would let a
/// caller write outside the App Group container, so the charset is restricted at
/// the type boundary rather than sanitised at each use site.
public struct LeaseKey: Hashable, Codable, Sendable, CustomStringConvertible {

    public let rawValue: String

    /// The permitted characters: ASCII alphanumerics plus `-`, `_` and `.`.
    ///
    /// `.` is permitted for readable names like `feed.digest`, but a key
    /// consisting only of dots is rejected below, which is what actually blocks
    /// `.` and `..` traversal.
    private static let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

    /// Bounded so a key cannot produce a filename the filesystem rejects.
    public static let maximumLength = 128

    public init?(_ rawValue: String) {
        guard !rawValue.isEmpty, rawValue.count <= Self.maximumLength else { return nil }
        guard rawValue.allSatisfy({ Self.allowed.contains($0) }) else { return nil }
        // Blocks "." and ".." and any all-dots variant. Without this check the
        // charset above would still admit path traversal.
        guard rawValue.contains(where: { $0 != "." }) else { return nil }
        self.rawValue = rawValue
    }

    /// Builds a key by *sanitising* instead of rejecting.
    ///
    /// Disallowed characters become `-`, over-long input is truncated, and input
    /// that sanitises to nothing usable becomes ``fallbackName``. Total by
    /// construction: there is no input for which this traps or fails, which is
    /// what lets call sites hold a `LeaseKey` from a literal without a `!` and
    /// without an optional to unwrap.
    ///
    /// Use this for names you control (a literal, a bundle identifier). Use
    /// ``init(_:)`` for anything that came from outside, where silently rewriting a
    /// name into a *different valid key* would be worse than refusing it -- two
    /// distinct inputs can sanitise to the same key, which would quietly merge two
    /// resources into one.
    public init(sanitising raw: String) {
        let truncated = raw.prefix(Self.maximumLength)
        let mapped = String(truncated.map { Self.allowed.contains($0) ? $0 : "-" })
        // `mapped.count <= maximumLength` because `map` is 1:1 over a prefix of at
        // most that length, so only the empty and all-dots cases remain.
        if mapped.isEmpty || !mapped.contains(where: { $0 != "." }) {
            self.rawValue = Self.fallbackName
        } else {
            self.rawValue = mapped
        }
    }

    /// Used by ``init(sanitising:)`` when the input sanitises to nothing usable.
    /// A compile-time constant that satisfies every rule above.
    public static let fallbackName = "unnamed-key"

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode(String.self)
        guard let key = LeaseKey(decoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\"\(decoded)\" is not a valid LeaseKey"
            )
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - FencingToken

/// A monotonically increasing epoch number for a single ``LeaseKey``.
///
/// This is the load-bearing type in the package. A lease deadline says *when* a
/// holder's claim lapses, which is only as trustworthy as the clock it was
/// measured against. A fencing token says *whether someone has since taken
/// over*, which needs no clock at all: the token increments only when the lease
/// changes hands, so a write carrying a token lower than the resource's
/// high-water mark is provably from a superseded holder and can be rejected on
/// the spot.
///
/// The idea is Martin Kleppmann's, from *How to do distributed locking* (2016).
/// The reason it matters more on iOS than on a server is that the pathological
/// case in that argument -- a holder paused for longer than its own lease, then
/// resuming and writing as if nothing happened -- is not a rare GC pause here.
/// It is `SIGSTOP` on app suspension, and it is routine.
public struct FencingToken: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {

    public let rawValue: UInt64

    /// The token of a lease being acquired for the first time.
    ///
    /// Starts at 1 so that 0 is available as "no epoch has ever existed", which
    /// lets ``FencedWriter`` distinguish an untouched resource from one written
    /// in the very first epoch.
    public static let initial = FencingToken(rawValue: 1)

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// The next epoch.
    ///
    /// Deliberately throwing rather than using `&+`. Wrapping here would let a
    /// new holder inherit a token *below* the resource's high-water mark, which
    /// silently inverts the safety property the whole package exists to provide.
    /// Exhausting `UInt64` requires 2^64 handovers and will not happen, but
    /// "will not happen" is not a reason to make the failure mode silent.
    public func next() throws -> FencingToken {
        guard rawValue < UInt64.max else {
            throw LeaseError.tokenSpaceExhausted
        }
        return FencingToken(rawValue: rawValue + 1)
    }

    public static func < (lhs: FencingToken, rhs: FencingToken) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { "#\(rawValue)" }
}

// MARK: - ProcessIdentity

/// Identifies one process *launch*.
///
/// Deliberately not just the PID. The kernel recycles PIDs, and on iOS the same
/// small numbers come back around quickly across extension launches -- so a
/// record saying "held by pid 431" can be misread as "held by me" by a different
/// process that happens to have inherited 431. Pairing the PID with a UUID
/// minted once per launch makes the identity unique in practice, and the UUID
/// alone would have been enough; the PID is retained because it is what a human
/// reads in a log.
public struct ProcessIdentity: Hashable, Codable, Sendable, CustomStringConvertible {

    public let processID: Int32
    public let launchID: UUID
    /// A human-readable role, e.g. `"app"`, `"share-extension"`, `"widget"`.
    public let label: String

    public init(processID: Int32, launchID: UUID, label: String) {
        self.processID = processID
        self.launchID = launchID
        self.label = label
    }

    private static let launchIDForThisProcess = UUID()

    /// The identity of the running process, stable for its whole lifetime.
    ///
    /// **This is a process identity, not a holder identity, and the difference
    /// matters.** Two `LeaseCoordinator`s built with `current(label:)` and the *same*
    /// label inside one process are the same identity, so the second `acquire` takes
    /// the **renewal** path and is handed the first one's live epoch. Both then believe
    /// they hold the lease, both writes are accepted, and the diagnostics report a
    /// renewal rather than a conflict -- because from the lease's point of view nothing
    /// unusual happened. It cannot distinguish callers it cannot tell apart.
    ///
    /// That is the right default: a lease coordinates *processes*, and within one
    /// process the app already has cheaper tools. But it means:
    ///
    /// - One coordinator per (process, label). Build it once and share it.
    /// - Concurrent in-process callers need an in-process gate as well.
    ///   ``CrossProcessSingleFlight`` is that gate, and its `inFlight` map exists for
    ///   exactly this reason.
    /// - If two *logically independent* holders must coexist in one process, give them
    ///   distinct identities with ``distinct(label:)``.
    public static func current(label: String) -> ProcessIdentity {
        ProcessIdentity(
            processID: Int32(truncatingIfNeeded: ProcessInfo.processInfo.processIdentifier),
            launchID: launchIDForThisProcess,
            label: label
        )
    }

    /// A fresh identity on every call, for logically independent holders inside one
    /// process that must contend with each other rather than share an epoch.
    ///
    /// Mostly useful in tests and in demos that simulate several processes. Production
    /// code coordinating real processes wants ``current(label:)``.
    public static func distinct(label: String) -> ProcessIdentity {
        ProcessIdentity(
            processID: Int32(truncatingIfNeeded: ProcessInfo.processInfo.processIdentifier),
            launchID: UUID(),
            label: label
        )
    }

    public var description: String { "\(label)(pid \(processID))" }
}

// MARK: - LeaseRecord

/// The durable state of a lease, as persisted in the shared container.
public struct LeaseRecord: Codable, Sendable, Equatable {

    public let key: LeaseKey
    public let holder: ProcessIdentity
    public let token: FencingToken
    /// Wall-clock instant the lease was granted.
    public let acquiredAt: Date
    /// Wall-clock instant the lease lapses. See ``LeaseClock`` for why this is
    /// wall-clock and therefore not trustworthy on its own.
    public let expiresAt: Date

    /// Whether the holder released voluntarily.
    ///
    /// A released record is a **tombstone**: the lease is available, but the record
    /// is retained so its ``token`` still marks how far the epoch sequence has got.
    ///
    /// Deleting the record on release instead -- the obvious implementation -- is a
    /// safety bug, and a subtle one, because it only bites after a handover. Delete
    /// it and the next acquirer starts again at ``FencingToken/initial``, *below* the
    /// high-water mark the resource is already holding. Two consequences, both bad:
    /// a resurrected holder from an earlier epoch compares equal to the current one
    /// and its stale write is accepted; and a legitimate new holder is fenced out
    /// permanently, because its freshly issued epoch is behind the resource forever.
    /// The tombstone is what keeps the epoch sequence monotonic across releases.
    public let isReleased: Bool

    public init(
        key: LeaseKey,
        holder: ProcessIdentity,
        token: FencingToken,
        acquiredAt: Date,
        expiresAt: Date,
        isReleased: Bool = false
    ) {
        self.key = key
        self.holder = holder
        self.token = token
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
        self.isReleased = isReleased
    }

    /// Tolerates records written before `isReleased` existed by defaulting it to
    /// `false`, so an upgrade in place reads old records as still-held rather than
    /// failing to decode and being discarded.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decode(LeaseKey.self, forKey: .key)
        self.holder = try container.decode(ProcessIdentity.self, forKey: .holder)
        self.token = try container.decode(FencingToken.self, forKey: .token)
        self.acquiredAt = try container.decode(Date.self, forKey: .acquiredAt)
        self.expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        self.isReleased = try container.decodeIfPresent(Bool.self, forKey: .isReleased) ?? false
    }

    /// Whether the lease has lapsed as of `now`.
    ///
    /// Expiry is inclusive: at exactly `expiresAt` the lease is already gone.
    /// Picking the inclusive boundary means two processes reading the identical
    /// instant can never *both* conclude they hold it.
    public func isExpired(at now: Date) -> Bool {
        now >= expiresAt
    }

    /// Whether someone currently holds this lease: not released, and not lapsed.
    public func isHeld(at now: Date) -> Bool {
        !isReleased && !isExpired(at: now)
    }

    /// The same epoch with a later deadline. The token is intentionally carried
    /// over -- a renewal is not a handover, so the holder's outstanding writes
    /// must stay valid.
    public func renewed(until newExpiry: Date) -> LeaseRecord {
        LeaseRecord(
            key: key,
            holder: holder,
            token: token,
            acquiredAt: acquiredAt,
            expiresAt: newExpiry,
            isReleased: false
        )
    }

    /// The tombstone left behind by a release. Keeps `token`; frees the lease.
    public func releasedTombstone() -> LeaseRecord {
        LeaseRecord(
            key: key,
            holder: holder,
            token: token,
            acquiredAt: acquiredAt,
            expiresAt: expiresAt,
            isReleased: true
        )
    }
}

// MARK: - EpochFloorProvider

/// A second, independent memory of how far the epoch sequence has advanced.
///
/// The lease record is the primary memory, but it can be lost -- a crash between
/// `open` and `rename` leaves a zero-length file, and the OS may reclaim a
/// container. If the record were the *only* memory, losing it would restart the
/// epoch at 1 while the resource still remembers a higher mark, which is the same
/// safety hole as deleting the record on release.
///
/// So the coordinator can consult the guarded resource itself. ``FencedWriter``
/// conforms, returning its high-water mark, and a new epoch is issued above
/// **both** the record and this floor.
///
/// The residual gap, stated rather than hidden: if the record is lost *and* the
/// resource has never been written, there is nothing left that remembers, and the
/// sequence does restart at 1. That window is narrow -- it needs a lease granted,
/// the record destroyed, and no write ever committed -- but it is real, and no
/// amount of layering closes it without a third durable witness.
public protocol EpochFloorProvider: Sendable {

    /// The highest epoch known to have written the guarded resource, or `nil` if it
    /// has never been written.
    func epochFloor() throws -> FencingToken?
}

// MARK: - Lease

/// A capability handle proving the bearer held `key` at epoch `token`.
///
/// The only way to obtain one is ``LeaseCoordinator/acquire(_:for:)``, and
/// ``FencedWriter`` will not accept a write without one. That is a deliberate API
/// choice: it makes "I forgot to take the lock" a compile error rather than a race
/// that shows up in production once a month.
///
/// It does **not** make holding one proof that nobody else is writing. Two
/// coordinators sharing a ``ProcessIdentity`` will both be handed the same live epoch
/// -- see ``ProcessIdentity/current(label:)``. A `Lease` proves *which epoch* you are
/// in, which is what the fence needs; it does not prove exclusivity against a caller
/// the lease cannot tell apart from you.
public struct Lease: Hashable, Sendable, CustomStringConvertible {

    public let key: LeaseKey
    public let token: FencingToken
    public let holder: ProcessIdentity
    /// The wall-clock deadline at the time of acquisition. Advisory only --
    /// safety comes from ``token``, not from this.
    public let expiresAt: Date

    init(key: LeaseKey, token: FencingToken, holder: ProcessIdentity, expiresAt: Date) {
        self.key = key
        self.token = token
        self.holder = holder
        self.expiresAt = expiresAt
    }

    public var description: String {
        "Lease(\(key) \(token) by \(holder))"
    }
}

// MARK: - Errors

public enum LeaseError: Error, Equatable, CustomStringConvertible {

    /// Another process holds an unexpired lease.
    case heldByAnotherProcess(holder: ProcessIdentity, until: Date)

    /// The write carried a token below the resource's high-water mark: someone
    /// else has taken over since this lease was granted.
    case fenced(presented: FencingToken, highWaterMark: FencingToken)

    /// The store could not be entered exclusively within the caller's budget.
    ///
    /// Distinct from ``heldByAnotherProcess``: this is contention on the short
    /// read-modify-write critical section, not on the lease itself. It means a
    /// peer was stopped *inside* the critical section, which is retryable; a
    /// held lease is not.
    case storeBusy(region: String)

    /// A release or renewal referenced an epoch that is no longer current.
    case notHolder(key: LeaseKey, presented: FencingToken, current: FencingToken?)

    /// `duration` was not a finite, positive, in-range number of seconds.
    case invalidDuration(TimeInterval)

    /// 2^64 handovers. See ``FencingToken/next()``.
    case tokenSpaceExhausted

    /// The persisted record could not be read or written.
    case storageFailure(String)

    public var description: String {
        switch self {
        case let .heldByAnotherProcess(holder, until):
            return "lease held by \(holder) until \(until)"
        case let .fenced(presented, highWaterMark):
            return "write fenced: presented \(presented), high-water mark \(highWaterMark)"
        case let .storeBusy(region):
            return "store busy: region \(region)"
        case let .notHolder(key, presented, current):
            let currentText = current.map(String.init(describing:)) ?? "none"
            return "not holder of \(key): presented \(presented), current \(currentText)"
        case let .invalidDuration(duration):
            return "invalid lease duration: \(duration)"
        case .tokenSpaceExhausted:
            return "fencing token space exhausted"
        case let .storageFailure(detail):
            return "storage failure: \(detail)"
        }
    }
}

// MARK: - Limits

public enum LeaseLimits {

    /// The shortest lease the coordinator will grant.
    ///
    /// A lease shorter than the time it takes to notice you have it is not a
    /// lock, it is a race with extra steps.
    public static let minimumDuration: TimeInterval = 0.001

    /// The longest lease the coordinator will grant (24 hours).
    ///
    /// Bounded because a lease is also the *recovery* time after a holder dies:
    /// an unbounded lease taken by a process that is then killed makes the
    /// resource unavailable for exactly that long.
    public static let maximumDuration: TimeInterval = 24 * 60 * 60

    /// Validates a caller-supplied duration.
    public static func validate(_ duration: TimeInterval) throws {
        guard duration.isFinite,
              duration >= minimumDuration,
              duration <= maximumDuration
        else {
            throw LeaseError.invalidDuration(duration)
        }
    }
}
