import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A short-lived, cross-process critical section backed by `flock`.
///
/// This is the only genuinely atomic primitive in the package, and both the lease
/// bookkeeping and the fenced write path are built on it. It is deliberately
/// small: acquire, run a few syscalls, release.
///
/// ## Why `flock` and not `NSFileCoordinator`
///
/// `NSFileCoordinator` coordinates between participants that are *running and
/// responsive* -- it messages peer coordinators and waits for replies, so a
/// suspended peer contributes a timeout rather than an answer. That is fine for
/// document save conflicts and wrong for a critical section, because on iOS the
/// common case is a peer that is not responsive.
///
/// `flock` is an advisory lock the kernel holds against an open file description.
/// Acquiring it is one atomic syscall, and the kernel drops it when the
/// descriptor closes -- including on `SIGKILL`, which is how an extension usually
/// dies. Acquisition here is non-blocking with a bounded retry, so a peer that is
/// stopped mid-section costs the caller its budget and no more.
///
/// ## Why the lock file is never the data file
///
/// Data files in this package are replaced by atomic `rename`, which swaps the
/// *inode* behind a path. A lock taken on a data file would be attached to an
/// inode that is no longer the one at that path, so two processes could hold
/// "the same" lock on two different objects and never serialise at all. Lock
/// files are created once and never replaced.
public struct FileMutex: Sendable {

    private let lockFileURL: URL
    private let budget: TimeInterval
    private let clock: any LeaseClock
    /// Included in `storeBusy` so the caller can tell which region was contended.
    private let regionName: String

    /// - Parameters:
    ///   - directory: Must already exist.
    ///   - regionName: Basename of the lock file; also the label in errors.
    ///   - budget: How long to retry before reporting contention. Clamped to
    ///     `[1ms, 5s]` -- an unbounded wait would reintroduce the deadlock that
    ///     using a lease instead of an OS lock was meant to avoid.
    public init(
        directory: URL,
        regionName: String,
        budget: TimeInterval = 0.25,
        clock: any LeaseClock = SystemLeaseClock()
    ) {
        self.lockFileURL = directory.appendingPathComponent("\(regionName).lock")
        self.regionName = regionName
        self.budget = Saturating.clamp(budget, to: 0.001...5.0)
        self.clock = clock
    }

    /// Runs `body` with the region held exclusively across all processes.
    ///
    /// - Throws: ``LeaseError/storeBusy(region:)`` if the region could not be entered
    ///   within `budget`; ``LeaseError/storageFailure(_:)`` on a syscall error;
    ///   or anything `body` throws.
    public func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(lockFileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw LeaseError.storageFailure(
                "open(\(lockFileURL.path)) failed: errno \(errno)"
            )
        }
        // Closing the descriptor is what releases the kernel lock, so it happens
        // on every exit path including a throw from `body`.
        defer { close(descriptor) }

        try acquire(descriptor)
        defer { flock(descriptor, LOCK_UN) }

        return try body()
    }

    /// Interval between retries. Short enough that a transient blip resolves
    /// without a visible stall, long enough not to burn a core spinning.
    private static let retryInterval: TimeInterval = 0.0002

    private func acquire(_ descriptor: Int32) throws {
        let start = clock.monotonicNanoseconds
        let (sum, overflowed) = start.addingReportingOverflow(
            Saturating.nanoseconds(fromSeconds: budget)
        )
        // If the monotonic clock is at its ceiling the honest reading is "the
        // budget is already spent", which makes the loop run one attempt rather
        // than spinning forever.
        let deadline = overflowed ? UInt64.max : sum

        // Bounded by attempts *as well as* by the clock. The clock bound alone
        // would spin forever under an injected clock that does not advance, and a
        // lock acquisition that can hang on a test double is a lock acquisition
        // that can hang.
        var attemptsRemaining = Saturating.int(
            from: (budget / Self.retryInterval).rounded(.up),
            clampedTo: 1...100_000
        )

        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
            let failure = errno
            guard failure == EWOULDBLOCK || failure == EINTR else {
                throw LeaseError.storageFailure("flock failed: errno \(failure)")
            }
            attemptsRemaining -= 1
            guard attemptsRemaining > 0, clock.monotonicNanoseconds < deadline else {
                throw LeaseError.storeBusy(region: regionName)
            }
            usleep(useconds_t(Saturating.int(
                from: Self.retryInterval * 1_000_000,
                clampedTo: 1...1_000_000
            )))
        }
    }
}

// MARK: - Atomic file IO

/// Atomic file primitives shared by the two file-backed stores.
///
/// `public` for one reason: ``reapStagingFiles(in:olderThan:now:)`` is maintenance a
/// *consumer* has to schedule, and an internal type would have made the README's
/// claim that a reaper exists true of the source and false of the API.
public enum AtomicFile {

    /// Reads `url`, returning `nil` if it does not exist or is empty.
    ///
    /// Internal: callers outside the package have no reason to bypass the stores.
    ///
    /// An empty file is the observable trace of a crash between `open` and
    /// `rename` in some earlier run, and is treated as absent.
    static func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return data.isEmpty ? nil : data
        } catch {
            throw LeaseError.storageFailure("read \(url.lastPathComponent): \(error)")
        }
    }

    /// Writes `data` to `url` via a temporary file and `rename`.
    ///
    /// POSIX `rename` is atomic, so a concurrent reader sees either the old
    /// contents or the new ones and never a partial write. A crash mid-write
    /// leaves the previous version intact rather than a torn one.
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
        } catch {
            throw LeaseError.storageFailure("stage \(url.lastPathComponent): \(error)")
        }
        guard rename(temporary.path, url.path) == 0 else {
            let failure = errno
            try? FileManager.default.removeItem(at: temporary)
            throw LeaseError.storageFailure("rename failed: errno \(failure)")
        }
    }

    static func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw LeaseError.storageFailure("remove \(url.lastPathComponent): \(error)")
        }
    }

    /// Deletes staging files older than `olderThan` seconds.
    ///
    /// ``write(_:to:)`` stages to a `.tmp` file and then renames. A process killed in
    /// that window -- the same window the rest of this package is built around --
    /// leaves the staging file behind, and nothing else ever collects it. Without a
    /// reaper that is genuine unbounded growth in a shared container.
    ///
    /// The age bound matters: a `.tmp` file belonging to a *live* writer must not be
    /// deleted out from under it, and there is no way to tell a live one from an
    /// abandoned one except by age. The default is deliberately far longer than any
    /// single write.
    ///
    /// - Returns: The number of files removed.
    @discardableResult
    public static func reapStagingFiles(
        in directory: URL,
        olderThan age: TimeInterval = 3_600,
        now: Date = Date()
    ) -> Int {
        guard age.isFinite, age > 0 else { return 0 }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return 0
        }
        var removed = 0
        for entry in entries where entry.pathExtension == "tmp" {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > age else { continue }
            if (try? FileManager.default.removeItem(at: entry)) != nil {
                removed = Saturating.increment(removed)
            }
        }
        return removed
    }
}
