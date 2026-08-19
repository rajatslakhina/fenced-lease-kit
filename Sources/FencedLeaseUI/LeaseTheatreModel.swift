// `ObservableObject` and `@Published` come from Combine, which does not exist on
// Linux. Guarding the whole file means the CI matrix can build the core module on
// Linux with `-warnings-as-errors` while this target compiles to an empty module
// there -- rather than the package simply not being buildable off Apple platforms.
#if canImport(SwiftUI)
import Foundation
import SwiftUI
import FencedLease

/// Drives the demo: two simulated processes contending for one key, with a clock
/// the operator controls.
///
/// The clock is manual on purpose. The bug this package exists to prevent -- a
/// process suspended past its own lease deadline resuming and overwriting its
/// successor's work -- is unreachable by tapping buttons at human speed against a
/// real clock. Making time an input turns it into a two-tap demonstration.
///
/// `@MainActor` because every property here is view state. The lease operations it
/// calls are synchronous and complete in microseconds, so there is no suspension
/// point inside a step and therefore no window in which the view could observe a
/// half-applied transition.
@MainActor
public final class LeaseTheatreModel: ObservableObject {

    // MARK: - Displayable state

    public struct PeerState: Identifiable, Sendable, Equatable {
        public let id: String
        public var label: String
        /// The epoch this peer believes it holds, if it holds a handle at all.
        public var heldToken: UInt64?
        public var isSuspended: Bool
        /// What happened on this peer's last action.
        public var lastMessage: String
    }

    public struct LogEntry: Identifiable, Sendable, Equatable {
        public let id = UUID()
        public let text: String
        public let kind: Kind

        public enum Kind: Sendable, Equatable {
            case granted
            case stolen
            case refused
            case written
            case fenced
            case note
        }
    }

    @Published public private(set) var peers: [PeerState] = []
    @Published public private(set) var log: [LogEntry] = []
    /// Wall-clock reading shown in the UI, as an offset from the start.
    @Published public private(set) var elapsedSeconds: Int = 0
    /// The value currently published, and the epoch that wrote it.
    @Published public private(set) var publishedSummary: String = "nothing published yet"
    @Published public private(set) var highWaterMark: UInt64?
    @Published public private(set) var diagnostics: LeaseDiagnostics = LeaseDiagnostics()

    /// How long a lease is granted for in the demo.
    public let leaseDuration: TimeInterval

    // MARK: - Machinery

    private let clock = ManualLeaseClock(wallTime: Date(timeIntervalSince1970: 1_000_000))
    private let store = InMemoryLeaseStore()
    private let storage = InMemoryFencedStorage()
    private let recorder = DiagnosticsRecorder()
    private let key: LeaseKey
    private let writer: FencedWriter<DemoPayload>
    private var coordinators: [String: LeaseCoordinator] = [:]
    /// The handle each peer is still holding -- possibly a stale one.
    private var handles: [String: Lease] = [:]

    struct DemoPayload: Codable, Sendable, Equatable {
        let writer: String
        let epoch: UInt64
    }

    private static let peerDefinitions: [(id: String, label: String)] = [
        (id: "app", label: "Host app"),
        (id: "share-extension", label: "Share extension"),
    ]

    public init(leaseDuration: TimeInterval = 30) {
        // `leaseDuration` is public API, so it can arrive as NaN, infinity, or
        // out-of-range. Validating here rather than trusting it is what stops
        // `LeaseTheatreView(leaseDuration: .nan)` from trapping later, both in the
        // `Int(...)` conversions this class used to do and inside `acquire`.
        do {
            try LeaseLimits.validate(leaseDuration)
            self.leaseDuration = leaseDuration
        } catch {
            self.leaseDuration = Self.fallbackLeaseDuration
        }
        // `init(sanitising:)` is total, so the demo holds a real key from a literal
        // with no optional to unwrap and no `!` anywhere in this file.
        self.key = LeaseKey(sanitising: "shared.digest")
        let writer = FencedWriter<DemoPayload>(
            storage: storage,
            clock: clock,
            recorder: recorder
        )
        self.writer = writer

        for definition in Self.peerDefinitions {
            coordinators[definition.id] = LeaseCoordinator(
                store: store,
                // `distinct`, not `current`: the demo simulates separate processes
                // inside one process, and `current(label:)` would give two peers
                // sharing a label the same identity. They differ by label here, so
                // either works -- but `distinct` states the intent and stays correct if
                // a future peer is added with a duplicate label.
                identity: ProcessIdentity.distinct(label: definition.id),
                clock: clock,
                recorder: recorder,
                // Without this the epoch sequence would restart at 1 whenever the
                // lease record went away, which is exactly the safety hole the
                // library documents. The demo wires it the way real callers should.
                epochFloor: writer
            )
            peers.append(
                PeerState(
                    id: definition.id,
                    label: definition.label,
                    heldToken: nil,
                    isSuspended: false,
                    lastMessage: "idle"
                )
            )
        }
        // `self.` matters: an unqualified `leaseDuration` here resolves to the
        // *parameter*, so a rejected value would be reported on screen while a
        // different one was actually in use.
        append(
            "Two processes, one shared key, a \(Self.wholeSeconds(self.leaseDuration))s lease.",
            .note
        )
        refresh()
    }

    /// Used when the caller supplies a duration the library would reject.
    static let fallbackLeaseDuration: TimeInterval = 30

    /// Whole seconds for display, without `Int(Double)`'s trap on NaN/infinity.
    static func wholeSeconds(_ seconds: TimeInterval) -> Int {
        Saturating.int(from: seconds.rounded(), clampedTo: 0...86_400)
    }

    // MARK: - Operator actions

    /// `peerID` tries to take the lease.
    public func acquire(_ peerID: String) {
        guard let coordinator = coordinators[peerID] else {
            append("Unknown peer \"\(peerID)\" -- nothing to acquire.", .refused)
            return
        }
        let previousToken = handles[peerID]?.token
        // Read the record *before* acquiring, so the log can distinguish the three
        // outcomes the way the coordinator does internally. Inferring it afterwards
        // from `token > 1` misreports a plain grant off a tombstone as a takeover --
        // and "granted" versus "taken from a peer we declared dead" is exactly the
        // distinction this demo exists to teach.
        let recordBefore = try? coordinator.inspect(key)
        let wasTakeover = recordBefore.map {
            !$0.isReleased && $0.isExpired(at: clock.wallTime)
        } ?? false

        do {
            let lease = try coordinator.acquire(key, for: leaseDuration)
            handles[peerID] = lease
            update(peerID) {
                $0.heldToken = lease.token.rawValue
                $0.lastMessage = "holds epoch #\(lease.token.rawValue)"
            }
            if previousToken == lease.token {
                append(
                    "\(label(peerID)) renewed epoch #\(lease.token.rawValue) "
                    + "(same epoch, later deadline).",
                    .granted
                )
            } else if wasTakeover {
                append("\(label(peerID)) took the lease at epoch #\(lease.token.rawValue).", .stolen)
            } else {
                append("\(label(peerID)) was granted epoch #\(lease.token.rawValue).", .granted)
            }
        } catch let error as LeaseError {
            update(peerID) { $0.lastMessage = describe(error) }
            append("\(label(peerID)) was refused: \(describe(error))", .refused)
        } catch {
            update(peerID) { $0.lastMessage = "unexpected: \(error)" }
            append("\(label(peerID)) hit an unexpected error.", .refused)
        }
        refresh()
    }

    /// `peerID` tries to publish using whatever handle it still holds.
    ///
    /// This is where the fence becomes visible: a suspended peer that resumes and
    /// writes is rejected here, not silently allowed to clobber its successor.
    public func write(_ peerID: String) {
        guard peers.contains(where: { $0.id == peerID }) else {
            append("Unknown peer \"\(peerID)\" -- nothing to write with.", .refused)
            return
        }
        guard let lease = handles[peerID] else {
            update(peerID) { $0.lastMessage = "no lease to write with" }
            append("\(label(peerID)) has no lease -- nothing to write with.", .refused)
            refresh()
            return
        }
        do {
            try writer.write(
                DemoPayload(writer: peerID, epoch: lease.token.rawValue),
                using: lease
            )
            update(peerID) { $0.lastMessage = "published at epoch #\(lease.token.rawValue)" }
            append("\(label(peerID)) published at epoch #\(lease.token.rawValue).", .written)
        } catch let LeaseError.fenced(presented, highWaterMark) {
            update(peerID) {
                $0.lastMessage = "fenced: #\(presented.rawValue) < #\(highWaterMark.rawValue)"
            }
            append(
                "\(label(peerID)) was FENCED -- presented #\(presented.rawValue), "
                + "resource is at #\(highWaterMark.rawValue). Its write was discarded.",
                .fenced
            )
        } catch {
            update(peerID) { $0.lastMessage = "write failed: \(error)" }
            append("\(label(peerID)) failed to write.", .refused)
        }
        refresh()
    }

    /// Marks a peer suspended and advances the clock past its lease, modelling the
    /// OS stopping it. This is the single step that makes the whole problem real.
    public func suspendPastExpiry(_ peerID: String) {
        guard peers.contains(where: { $0.id == peerID }) else {
            append("Unknown peer \"\(peerID)\" -- nothing to suspend.", .refused)
            return
        }
        update(peerID) {
            $0.isSuspended = true
            $0.lastMessage = "suspended by the OS"
        }
        append("\(label(peerID)) was suspended; its lease will lapse.", .note)
        advance(by: leaseDuration + 1)
    }

    /// The peer resumes, still holding whatever handle it had.
    public func resume(_ peerID: String) {
        guard peers.contains(where: { $0.id == peerID }) else {
            append("Unknown peer \"\(peerID)\" -- nothing to resume.", .refused)
            return
        }
        update(peerID) {
            $0.isSuspended = false
            $0.lastMessage = "resumed, still holding its old handle"
        }
        append("\(label(peerID)) resumed. It does not know time passed.", .note)
        refresh()
    }

    /// Moves wall time forward.
    public func advance(by seconds: TimeInterval) {
        clock.advance(by: seconds)
        elapsedSeconds = Saturating.add(
            elapsedSeconds,
            Saturating.int(from: seconds.rounded(), clampedTo: 0...86_400)
        )
        refresh()
    }

    /// Resets everything to a clean start.
    public func reset() {
        for peerID in coordinators.keys {
            if let lease = handles[peerID] {
                try? coordinators[peerID]?.release(lease)
            }
        }
        handles.removeAll()
        recorder.reset()
        log.removeAll()
        // `elapsedSeconds` is deliberately NOT zeroed. The manual clock cannot be
        // rewound -- a monotonic reading that goes backwards is not something this
        // package is allowed to assume -- so zeroing the display would put the readout
        // and the clock driving expiry out of step, and the header would lie.
        for index in peers.indices {
            peers[index].heldToken = nil
            peers[index].isSuspended = false
            peers[index].lastMessage = "idle"
        }
        append("Reset. The published value survives -- and so does its epoch.", .note)
        refresh()
    }

    /// Runs the canonical failure story end to end, so the demo has a
    /// one-tap path to its own headline claim.
    public func runFencingScenario() {
        reset()
        append("--- Scenario: suspended holder resumes after a peer took over ---", .note)
        acquire("app")
        suspendPastExpiry("app")
        acquire("share-extension")
        write("share-extension")
        resume("app")
        write("app")
        append(
            "The host app's write was rejected and the share extension's value "
            + "survived. A deadline-only lock would have lost it.",
            .note
        )
    }

    // MARK: - Derived state

    private func refresh() {
        diagnostics = recorder.current
        highWaterMark = (try? writer.highWaterMark())?.rawValue
        // `try?` flattens the nested optional, so one `if let` is enough here.
        if let readBack = try? writer.readEnvelope() {
            publishedSummary = "\"\(readBack.envelope.writerLabel)\" at epoch "
                + "#\(readBack.value.epoch)"
        } else {
            publishedSummary = "nothing published yet"
        }
        for index in peers.indices {
            let peerID = peers[index].id
            peers[index].heldToken = handles[peerID]?.token.rawValue
        }
    }

    private func update(_ peerID: String, _ mutate: (inout PeerState) -> Void) {
        guard let index = peers.firstIndex(where: { $0.id == peerID }) else { return }
        mutate(&peers[index])
    }

    private func label(_ peerID: String) -> String {
        peers.first { $0.id == peerID }?.label ?? peerID
    }

    private func append(_ text: String, _ kind: LogEntry.Kind) {
        log.append(LogEntry(text: text, kind: kind))
        // Bounded so a long session cannot grow the log without limit.
        if log.count > Self.maximumLogEntries {
            log.removeFirst(log.count - Self.maximumLogEntries)
        }
    }

    private static let maximumLogEntries = 200

    private func describe(_ error: LeaseError) -> String {
        switch error {
        case let .heldByAnotherProcess(holder, _):
            return "held by \(holder.label)"
        case let .fenced(presented, highWaterMark):
            return "fenced #\(presented.rawValue) < #\(highWaterMark.rawValue)"
        case .storeBusy:
            return "critical section busy"
        case .notHolder:
            return "no longer the holder"
        case let .invalidDuration(duration):
            return "invalid duration \(duration)"
        case .tokenSpaceExhausted:
            return "epoch space exhausted"
        case let .storageFailure(detail):
            return "storage failure: \(detail)"
        }
    }
}
#endif
