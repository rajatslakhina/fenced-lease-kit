# FencedLease

**Your iOS app and its extensions share one container and no memory. The lock you reach for first deadlocks when a holder is killed. The lock you reach for instead silently loses data when a holder is merely *paused* — and iOS pauses processes as a matter of routine.**

`FencedLease` is cross-process mutual exclusion for App Group containers, built on a lease plus a fencing token. It treats the iOS process model as what it actually is: a distributed system with an unusually high pause rate.

---

## Why this matters

An iOS app is not one process. It is a host app, a share extension, a widget, a notification service extension, and increasingly a Live Activity — all reading and writing one App Group container, none able to see each other's memory, any of them able to be suspended or killed at an instant not of their choosing.

Give two of them the same job and you get the usual pathology: both compute the same expensive artifact, then race to publish, and the loser's write lands second and wins.

The reflexive fix is a lock. All three obvious locks are wrong, in three different directions:

| Approach | Fails when | Failure mode |
|---|---|---|
| A boolean "is locked" flag in the container | The holder is jetsammed before clearing it | **Permanent deadlock.** The flag says locked forever; nothing is coming to clear it. |
| `flock` held for the duration of the work | Never deadlocks — the kernel drops it on death | **Cannot express a claim that outlives a process.** The automatic release *is* the problem. |
| A lease with an expiry deadline | The holder is *paused*, not dead | **Silent data loss.** It resumes after its lease lapsed and overwrites the peer that took over. |

That third row is Martin Kleppmann's argument from [*How to do distributed locking*](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html) (2016). His pathological case is a garbage-collection pause long enough to outlast a lease — on a server, a tail event you argue about.

On iOS it is `SIGSTOP`, it is the documented behaviour of app suspension, and it happens every time the user swipes to the home screen.

So this package applies the standard answer: **a fencing token.**

---

## The design in one comparison

A lease deadline answers *"when does my claim lapse?"* — only as trustworthy as the clock behind it. A persisted deadline must be wall-clock (a monotonic reading is meaningless to another process and worthless after a reboot), and a wall clock jumps: NTP steps it, the user edits the date, the timezone recalculates.

A fencing token answers a better question: **"has anyone taken over since?"** It needs no clock at all.

```swift
let lease = try coordinator.acquire(key, for: 30)   // epoch #4
// ... the OS suspends this process for two minutes ...
try writer.write(digest, using: lease)             // throws .fenced(#4, #5)
```

The resource stores the highest epoch that ever wrote it. The write path is one comparison:

```swift
if presented < highWaterMark { throw .fenced(...) }
```

Equality is accepted, not rejected: a holder writes many times within one epoch, and a fence at `<=` would make the lease useless.

That comparison is sufficient for safety — **but only because of an invariant that has to be defended separately.**

---

## The invariant the fence rests on

> **Every epoch issued for a key is strictly greater than every epoch previously issued for that key.**

The fence compares epoch numbers. An epoch sequence that can go backwards makes it *worse than useless* — it starts rejecting legitimate writers and accepting stale ones. Given monotonicity, the argument closes:

- **Nobody took over** → the high-water mark equals this holder's epoch → accepted. Correct: no peer has written, so there is nothing to clobber. This holds **even if the lease expired**, which is why the writer never consults the deadline.
- **Somebody took over** → a strictly greater epoch was issued to them → the stale holder's token is lower → rejected.

Everything the wall clock is bad at now costs **liveness** (a handover sooner or later than intended) and never **safety**.

Keeping the sequence monotonic takes two mechanisms, and each covers a case the other cannot.

**1. A release leaves a tombstone, not a deletion.** Deleting the record on release is the obvious implementation and it is a safety bug. Delete it and the next acquirer starts again at epoch 1, *below* the mark the resource already holds. Two consequences, both bad: a resurrected holder from an earlier epoch compares **equal** to the current one and its stale write is accepted; and a legitimate new holder is fenced out **permanently**, because its freshly issued epoch is behind the resource forever. `LeaseRecord.isReleased` marks the record available while preserving its token.

**2. `EpochFloorProvider` gives the sequence a second memory.** The lease record can be *lost* — a crash between `open` and `rename` leaves a zero-length file; the OS may reclaim a container. If the record were the only memory, losing it would restart the sequence with the same consequences. So the coordinator also asks the guarded resource how far it has seen. `FencedWriter` conforms, returning its high-water mark, and a new epoch is issued above **both**.

**The residual gap, stated rather than hidden:** if the record is lost *and* the resource has never been written, nothing remembers, and the sequence does restart at 1. That needs a lease granted, the record destroyed, and no write ever committed. It is narrow, but it is real, and no amount of layering closes it without a third durable witness. `testWithoutAFloorLosingTheRecordRestartsTheSequence` pins the behaviour so it stays a documented property rather than a surprise.

---

## Two mechanisms, two jobs

Collapsing these is the usual mistake, so they are separate types:

- **`FileMutex`** — a short cross-process critical section over `flock`. Held for microseconds. Its only job is making the lease bookkeeping's read-modify-write atomic. The kernel drops it on `SIGKILL`, which is exactly what makes it unusable for the second job.
- **The lease** — long-lived, crash-tolerant exclusion over the actual resource. Survives the holder's death, because nothing automatically releases it.

### Rejected alternatives

**`NSFileCoordinator`** — the Apple-blessed answer, and the wrong tool. It coordinates between participants that are *running and responsive*: it messages peer coordinators and waits for replies, so a suspended peer contributes a timeout rather than an answer. Fine for document save conflicts. Wrong for a critical section, because on iOS the common case *is* a peer that is not responsive.

**Locking the record file itself** — the record is replaced by atomic `rename`, which swaps the inode behind the path. A lock on the record file attaches to an inode no longer at that path, so two processes hold "the same" lock on two different objects and never serialise. Lock files are created once and never replaced.

**Blocking `flock`** — reintroduces the indefinite wait that using a lease was meant to avoid. Acquisition is non-blocking with a retry bounded by *both* a clock deadline and an attempt count. The attempt bound exists because a clock bound alone spins forever under an injected clock that does not advance, and a lock that can hang on a test double is a lock that can hang.

**Monotonic deadlines** — correct about elapsed time, meaningless across processes, gone after a reboot. Rejected for anything persisted; used only for local scheduling. `LeaseClock` exposes both readings and says which is for what.

**Reusing the epoch on self-reacquire** — the subtle one. Finding your own name on an *expired* record reads as "still mine". It is not: crossing your own expiry must invalidate handles captured *before* the suspension, because a resumed process cannot know what happened while it was stopped. `SelfReacquisitionPolicy` exists as a seam so the suite can inject the wrong answer into the real coordinator and show a pre-suspension handle clobbering post-resume work.

**Making `LeaseCoordinator` an actor** — no `await` exists in its critical path, so there is no suspension point to be re-entered across, and an actor would add a hop without buying a guarantee the store does not already provide. The cost, named rather than buried: `acquire` briefly **blocks its calling thread**, bounded by the store's budget. `CrossProcessSingleFlight` documents the same hazard where it launches a leader onto the cooperative pool.

### One deliberate asymmetry

A corrupt **lease record** is treated as absent. A corrupt **fenced envelope** throws.

That looks inconsistent and is load-bearing. A lost lease record costs mutual exclusion for one epoch and, thanks to the epoch floor above, nothing else. A lost envelope resets the high-water mark to nothing and **re-admits every superseded writer**, silently converting a corrupt file into exactly the data loss the fence exists to prevent. The fence's memory lives with the resource for this reason.

---

## What's in it

| Type | Role |
|---|---|
| `FencingToken` | Monotonic epoch. `next()` throws at `UInt64.max` rather than wrapping — wrapping would hand a new epoch a token *below* the mark and invert the safety property. |
| `LeaseCoordinator` | `acquire` / `renew` / `release` / `withLease` / `isHeld`. Enforces the monotonicity invariant above. |
| `LeaseRecord` | Includes `isReleased` (the tombstone) and a custom decoder that defaults it, so records written before it existed read as still-held rather than failing to decode and being discarded. |
| `EpochFloorProvider` | The sequence's second memory. `FencedWriter` conforms. |
| `LeaseStore` | The atomicity seam. `InMemoryLeaseStore` and `FileLeaseStore`, held to one shared conformance suite — including that both **refuse re-entry**, so the fake cannot be more forgiving than the real store. |
| `FencedStorage` | Same pattern for the resource, with its own shared conformance suite. |
| `FileMutex` | The one genuinely atomic primitive: `flock` on a never-replaced lock file, bounded retry. |
| `AtomicFile.reapStagingFiles` | Public maintenance a consumer must schedule. A process killed between `write` and `rename` leaks a `.tmp` file that nothing else collects; the library does not reap on its own, because deleting a staging file out from under a live writer is worse than leaving it. Age-bounded for the same reason. |
| `FencedWriter` | The write path and the single comparison. Encodes *outside* the critical section, so one writer's serialisation cost cannot stall its peers. |
| `CrossProcessSingleFlight` | Runs an expensive computation once across all peers. Deduplicates in-process (necessary, not an optimisation — every task in one process shares a `ProcessIdentity`, so the lease alone cannot tell them apart) and cross-process via the lease. |
| `LeaseDiagnostics` | `stealsFromExpiredLease` and `fencedWriteRejections` are the two numbers that make an invisible failure visible. Counters saturate; a telemetry counter must never crash the app it observes. |
| `ProcessIdentity` | PID **plus** a per-launch UUID. The kernel recycles PIDs and iOS extension launches cycle through the same low numbers, so identity by PID alone lets a fresh process mistake a stale record for its own. Note the sharp edge documented on `current(label:)`: it is a *process* identity, so two coordinators built with the same label in one process share an epoch rather than contending. `distinct(label:)` is the escape hatch. |
| `LeaseKey` | Validated at the type boundary, because the store interpolates it into a filename and `../` would escape the container. Also a total `init(sanitising:)` so call sites hold a key from a literal without a `!`. |
| `ManualLeaseClock` | Ships in the production module on purpose: consumers testing their own lease-dependent code need the same control over time that this suite has. |

`FencedLeaseUI` adds `LeaseTheatreView` — the scenario driven by a manual clock, because at real speed the bug is unreachable by hand.

---

## Usage

```swift
import FencedLease

struct Digest: Codable, Sendable { let items: Int }

guard let container = FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: "group.com.example.app"),
      let key = LeaseKey("feed.digest")
else { return }

let directory = container.appendingPathComponent("leases")
let storage = try FileFencedStorage(directory: directory, resourceName: key)
let writer = FencedWriter<Digest>(storage: storage)
let coordinator = LeaseCoordinator(
    store: try FileLeaseStore(directory: directory),
    identity: .current(label: "share-extension"),
    epochFloor: writer   // strongly recommended — see the invariant above
)

let lease = try coordinator.acquire(key, for: 30)
defer { try? coordinator.release(lease) }

do {
    try writer.write(Digest(items: 42), using: lease)
} catch let LeaseError.fenced(presented, highWaterMark) {
    // A peer took over while we were suspended. Its value is authoritative; ours is
    // stale. Re-read rather than retrying the write.
    print("fenced: held \(presented), resource at \(highWaterMark)")
}
```

Compute once across every process:

```swift
let flight = CrossProcessSingleFlight(coordinator: coordinator, writer: writer)

let outcome = try await flight.value(
    for: key, leaseDuration: 60, maxWait: 5, staleAfter: 300
) {
    await expensiveEmbedding(of: item)   // runs in one process, not five
}
```

---

## Verification

**What was actually executed**, on Swift 6.0.3 (aarch64 Linux):

- Clean build from a deleted `.build`: `swift build --build-tests -Xswiftc -warnings-as-errors` → **0 warnings**.
- `swift test` → **103 tests, 0 failures**, stable across repeated runs.
- Both re-run against a fresh `git archive` of this repository's `main`, so the numbers describe the pushed tree rather than a local working copy.

**Through real files and real `flock` syscalls** (`CrossProcessLeaseTests`):

- `testSuspendedHolderIsFencedOutAfterAPeerTakesOver` — the headline scenario end to end.
- `testManyThreadsContendingThroughFlockProduceExactlyOneHolder` — 16 real `Thread`s released simultaneously from a barrier; exactly one wins. The barrier is the point: without it the threads could finish serially and the test would pass against a store with no locking at all.
- `testAPeerStoppedInsideTheCriticalSectionReportsStoreBusyRatherThanBlocking` — a peer parked *inside* the critical section costs the caller its budget and no more.
- `testACorruptFencedEnvelopeFailsLoudlyInsteadOfResettingTheHighWaterMark` — the asymmetry above, pinned.
- `testAnEmptyLeaseRecordIsTreatedAsAbsentRatherThanBrickingTheKey` — and asserts the recovered holder can actually *write*, which is the part the epoch floor makes true.

**In memory, against `InMemoryLeaseStore` / `ForgetfulLeaseStore`** — no filesystem, no syscalls, because these test the *epoch algebra* rather than the storage:

- `testAStaleHolderCannotCollideWithANewHolderOnTheSameEpoch` — the regression test for the release/epoch-reset bug described above.
- `testEpochSurvivesLosingTheLeaseRecordWhenAFloorIsWired`, and `testWithoutAFloorLosingTheRecordRestartsTheSequence` asserting the residual gap.
- `testRepeatedAcquireAndReleaseCyclesAdvanceTheEpochEveryTime` — strictly increasing with no repeats, as a property rather than a spot check.

**On the `flock` claim specifically:** the Linux man page documents that separate file descriptors are treated independently *even within one process*, and `FileMutex` opens a fresh descriptor per entry — so two store instances here contend through the kernel exactly as two processes would. That is **verified on Linux**. Darwin's `flock(2)` page carries no equivalent sentence and no test here has yet run on Darwin, so treat the cross-process evidence as Linux-verified and Darwin-plausible.

**Mutation testing — the load-bearing claims on this page were checked by breaking the code and confirming the suite notices.** Each row is a single edit to production source, with XCTest's summary failure count against the same 103 tests (distinct failing test *cases* are fewer):

| Mutation | Failures |
|---|---|
| Fence comparison removed from `FencedWriter.write` | 22 |
| `release` deletes the record instead of tombstoning | 15 |
| `StrictSelfReacquisition` returns `true` unconditionally | 8 |
| `CrossProcessSingleFlight`'s `defer`-release removed (lease leak) | 6 |
| Epoch floor ignored (`floor = nil`) | 5 |
| `InMemoryFencedStorage`'s lock and re-entrancy guard removed | 2 |
| `release`'s `!isReleased` guard removed | 2 |
| Expiry boundary flipped from `>=` to `>` | 1 |
| `CrossProcessSingleFlight`'s generation guard removed | 1 |

`InMemoryLeaseStore`'s lock and guard removed is a tenth row with no number: the suite does not fail, it **segfaults** inside `LeaseCoordinator.acquire`, which is what an unsynchronised dictionary under 32 threads does.

Three of those also ship as permanent tests, so the checks stay pinned rather than being verified once:

- `testWithoutTheFenceTheSupersededWriterDestroysTheNewerValue` — `UnfencedWriterForTesting` skips the comparison; the stale write lands and walks the high-water mark backwards.
- `testCrossingOwnExpiryMustInvalidateHandlesHeldBeforeTheSuspension` — injects the wrong `SelfReacquisitionPolicy` into the **real** coordinator (it does not reimplement it alongside) and asserts a pre-suspension handle clobbers post-resume work.
- `testAStorageFailureDoesNotLeakTheLease` — a corrupt envelope on the double-check read used to leave the key claimed for the full lease duration. Uses a 24-hour lease so a leak is unmistakable.

**What was *not* run.** Three separate things, because they are separate:

1. **The SwiftUI layer has never been compiled by anything.** `FencedLeaseUI`'s views compile away behind `#if canImport(SwiftUI)` on Linux, so the run above does not type-check `LeaseTheatreView`. Only the macOS CI job will.
2. **`LeaseTheatreModel` — the view model — *has* been compiled and executed**, against a minimal `ObservableObject`/`@Published` shim on Linux. That is where the demo transcript in the companion repo comes from, and how the NaN/infinity input handling was checked.
3. **Nothing has been run on a Simulator.** See the demo repo for the full disclosure; building for a Simulator and running on one are stated there as two separate facts.

**CI status:** the workflow runs a Linux job (`swift:6.0`, `-warnings-as-errors`, build + test) and a `macos-15` job (every target including SwiftUI, plus an iOS-Simulator compile of `FencedLeaseUI` at a `generic/platform=iOS Simulator` destination). Read the current result on the [Actions tab](https://github.com/rajatslakhina/fenced-lease-kit/actions) rather than trusting a run quoted here, which goes stale on the next commit.

---

## Demo app

**[fenced-lease-kit-demo-app](https://github.com/rajatslakhina/fenced-lease-kit-demo-app)** — a separate Xcode project consuming this package as a remote dependency. It is where the fencing scenario is a button, and where the Simulator disclosure lives in full.

## Requirements

Swift 6.0+ · iOS 17+ · macOS 14+. Only these two platforms are declared in `Package.swift`, because these are the two the CI matrix actually builds; declaring more would be an untested claim.

## Licence

MIT — see [LICENSE](LICENSE).
