import Foundation
import XCTest
@testable import FencedLease

// MARK: - Key helpers

/// Builds a key, failing the test rather than force-unwrapping.
///
/// `LeaseKey.init?` is failable by design, and a `!` here would turn a typo in a
/// test literal into a crash that takes the whole suite with it.
func requireKey(
    _ raw: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> LeaseKey {
    guard let key = LeaseKey(raw) else {
        XCTFail("\"\(raw)\" should be a valid LeaseKey", file: file, line: line)
        throw TestFailure.invalidFixture
    }
    return key
}

enum TestFailure: Error {
    case invalidFixture
    case unexpectedSuccess
}

/// A ``FencedStorage`` that fails reads on demand, modelling a corrupt envelope.
///
/// Used to prove the leader releases its lease on error paths that are *not*
/// `.fenced` -- the case where a corrupt envelope would otherwise convert a loud,
/// expected failure into a resource locked for the whole lease duration.
final class FailingFencedStorage: FencedStorage, @unchecked Sendable {

    private let lock = NSRecursiveLock()
    private var envelope: FencedEnvelope?
    private var depth = 0
    private var entries = 0
    /// Entries before failures begin. Lets a test let the *fast path* read succeed and
    /// fail only the read that happens after the lease has been taken -- which is the
    /// path where a missing release actually leaks something.
    private var healthyEntries = Int.max

    func failFromEntry(_ index: Int) {
        lock.lock()
        defer { lock.unlock() }
        healthyEntries = max(0, index)
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func withExclusiveAccess<T>(
        _ body: (FencedEnvelope?) throws -> (FencedEnvelope?, T)
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard depth == 0 else {
            throw LeaseError.storeBusy(region: "failing-storage (re-entered)")
        }
        depth += 1
        defer { depth -= 1 }

        let index = entries
        entries += 1
        if index >= healthyEntries {
            throw LeaseError.storageFailure("injected: envelope unreadable")
        }
        let (replacement, result) = try body(envelope)
        if let replacement { envelope = replacement }
        return result
    }
}

func identity(_ label: String) -> ProcessIdentity {
    // A distinct launchID per call models genuinely different process launches,
    // which is what the coordinator's holder comparison keys on.
    ProcessIdentity(processID: 1000, launchID: UUID(), label: label)
}

// MARK: - Temporary directories

/// Creates a unique directory and removes it at teardown.
final class TemporaryDirectory {

    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fenced-lease-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func contents() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.sorted() ?? []
    }
}

// MARK: - Deliberately broken collaborators

/// A writer that skips the fence check entirely.
///
/// This exists so the test suite can prove the fence is *load-bearing* rather
/// than merely present. Several tests run the identical stale-write scenario
/// through both this type and ``FencedWriter`` and assert they disagree: this one
/// accepts the superseded write and destroys the newer value, the real one
/// rejects it. A test that only ever exercised the correct implementation could
/// not tell the difference between a working fence and no fence at all.
struct UnfencedWriterForTesting<Value: Codable & Sendable>: Sendable {

    let storage: any FencedStorage

    /// Last-writer-wins with no token comparison -- the naive implementation.
    func write(_ value: Value, using lease: Lease) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(value)
        try storage.withExclusiveAccess { _ in
            let envelope = FencedEnvelope(
                acceptedToken: lease.token,
                payload: encoded,
                writtenAt: Date(timeIntervalSince1970: 0),
                writerLabel: lease.holder.label
            )
            return (envelope, ())
        }
    }
}

/// The tempting-but-wrong self-reacquisition policy: "my name is on the record,
/// therefore it is still mine", regardless of whether the lease lapsed.
///
/// Injected into the **real** ``LeaseCoordinator`` -- not reimplemented alongside it.
/// That distinction is the whole value of this type. A test double that reimplements
/// the decision proves only that the double is broken; injecting the broken decision
/// into the production code path proves the production decision is what prevents the
/// data loss.
struct HolderNameOnlySelfReacquisition: SelfReacquisitionPolicy {
    func mayKeepEpoch(expired: Bool) -> Bool { true }
}

/// A ``LeaseStore`` that forgets everything on demand, modelling the container being
/// reclaimed or a record being corrupted.
///
/// Used to prove the epoch sequence survives losing the record -- which it can only
/// do via ``EpochFloorProvider``.
final class ForgetfulLeaseStore: LeaseStore, @unchecked Sendable {

    private let lock = NSRecursiveLock()
    private var records: [LeaseKey: LeaseRecord] = [:]
    private var depth = 0

    func withExclusiveAccess<T>(
        to key: LeaseKey,
        _ body: (LeaseRecord?) throws -> (LeaseMutation, T)
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard depth == 0 else {
            throw LeaseError.storeBusy(region: "\(key.rawValue) (re-entered)")
        }
        depth += 1
        defer { depth -= 1 }

        let (mutation, result) = try body(records[key])
        switch mutation {
        case .leave: break
        case let .store(record): records[key] = record
        case .remove: records[key] = nil
        }
        return result
    }

    /// Drops every record, as a wiped or corrupted container would.
    func forgetEverything() {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll()
    }
}

/// An ``EpochFloorProvider`` returning a value the test sets directly, so floor
/// behaviour can be driven without a real resource behind it.
final class StubEpochFloor: EpochFloorProvider, @unchecked Sendable {

    private let lock = NSLock()
    private var floor: FencingToken?

    init(_ floor: FencingToken? = nil) {
        self.floor = floor
    }

    func set(_ newFloor: FencingToken?) {
        lock.lock()
        defer { lock.unlock() }
        floor = newFloor
    }

    func epochFloor() throws -> FencingToken? {
        lock.lock()
        defer { lock.unlock() }
        return floor
    }
}

// MARK: - Concurrency helpers

/// A counter safe to increment from many tasks at once.
actor CallCounter {
    private(set) var count = 0
    func increment() { count = Saturating.increment(count) }
}

/// A lock-guarded collector usable from GCD blocks, which are `@Sendable` but not
/// `async` -- so an actor is not reachable from inside them.
final class Collector<Element>: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(element)
    }

    var elements: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int { elements.count }
}

/// Asserts `expression` throws a ``LeaseError`` matching `predicate`.
func assertLeaseError(
    _ expression: () throws -> Void,
    _ predicate: (LeaseError) -> Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        try expression()
        XCTFail("expected a LeaseError (\(message)) but the call succeeded", file: file, line: line)
    } catch let error as LeaseError {
        XCTAssertTrue(predicate(error), "\(message) -- got \(error)", file: file, line: line)
    } catch {
        XCTFail("expected a LeaseError (\(message)) but got \(error)", file: file, line: line)
    }
}
