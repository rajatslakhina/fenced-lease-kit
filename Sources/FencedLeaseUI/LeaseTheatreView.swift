#if canImport(SwiftUI)
import SwiftUI
import FencedLease

/// An interactive demonstration of the fencing invariant.
///
/// The screen is built around one claim: a process suspended past its own lease
/// deadline must not be able to overwrite the work of the peer that took over. Tap
/// **Run the fencing scenario** and the log shows exactly that sequence ending in a
/// rejected write; the counters show the rejection was recorded rather than
/// swallowed.
///
/// Everything is driven by a manual clock, because at real speed the bug is
/// unreachable by hand -- you would have to keep an app suspended for thirty
/// seconds while tapping in another process.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
public struct LeaseTheatreView: View {

    @StateObject private var model: LeaseTheatreModel

    /// - Parameter leaseDuration: Seconds a demo lease is granted for. The host app
    ///   owns this value so the demo target has a real reason to import the core
    ///   module and configure the view, rather than importing something it never
    ///   uses. A value the library would reject (NaN, infinity, out of range) is
    ///   replaced with a working default rather than trapping -- see
    ///   ``LeaseTheatreModel/init(leaseDuration:)``.
    ///
    /// The initialiser is `@MainActor` because it constructs a `@MainActor` model
    /// inside `StateObject`'s escaping autoclosure, which a nonisolated context
    /// cannot do under Swift 6's actor-isolation checking.
    public init(leaseDuration: TimeInterval = 30) {
        _model = StateObject(wrappedValue: LeaseTheatreModel(leaseDuration: leaseDuration))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    scenarioButton
                    resourceCard
                    ForEach(model.peers) { peer in
                        peerCard(peer)
                    }
                    countersCard
                    logCard
                }
                .padding()
            }
            .navigationTitle("Fenced Lease")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Two processes, one shared key")
                .font(.headline)
            Text(
                "A lease deadline is only as trustworthy as the clock behind it. "
                + "An epoch number needs no clock at all -- it only has to say whether "
                + "someone else has taken over since."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            // `Int(model.leaseDuration)` would trap on a NaN or infinite value.
            // The model already substitutes a valid duration, so this is defence in
            // depth -- but a display helper is the wrong place to rely on that.
            Text(
                "wall clock: +\(model.elapsedSeconds)s  ·  "
                + "lease: \(LeaseTheatreModel.wholeSeconds(model.leaseDuration))s"
            )
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
    }

    private var scenarioButton: some View {
        VStack(spacing: 8) {
            Button {
                model.runFencingScenario()
            } label: {
                Text("Run the fencing scenario")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button("Reset") { model.reset() }
                .buttonStyle(.bordered)
        }
    }

    private var resourceCard: some View {
        card("Shared resource") {
            LabeledContent("published") {
                Text(model.publishedSummary).font(.caption.monospaced())
            }
            LabeledContent("high-water epoch") {
                Text(model.highWaterMark.map { "#\($0)" } ?? "none")
                    .font(.caption.monospaced())
            }
        }
    }

    private func peerCard(_ peer: LeaseTheatreModel.PeerState) -> some View {
        card(peer.label) {
            HStack(spacing: 8) {
                Circle()
                    .fill(peer.isSuspended ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(peer.isSuspended ? "suspended" : "running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(peer.heldToken.map { "holds #\($0)" } ?? "no lease")
                    .font(.caption.monospaced())
            }
            Text(peer.lastMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { peerButtons(peer) }
                VStack(spacing: 8) { peerButtons(peer) }
            }
        }
    }

    @ViewBuilder
    private func peerButtons(_ peer: LeaseTheatreModel.PeerState) -> some View {
        Button("Acquire") { model.acquire(peer.id) }
            .buttonStyle(.bordered)
        Button("Write") { model.write(peer.id) }
            .buttonStyle(.bordered)
        if peer.isSuspended {
            Button("Resume") { model.resume(peer.id) }
                .buttonStyle(.bordered)
        } else {
            Button("Suspend") { model.suspendPastExpiry(peer.id) }
                .buttonStyle(.bordered)
        }
    }

    private var countersCard: some View {
        card("Counters") {
            counter("granted", model.diagnostics.acquisitions)
            counter("renewed", model.diagnostics.renewals)
            counter("taken from an expired lease", model.diagnostics.stealsFromExpiredLease)
            counter("refused (live holder)", model.diagnostics.contentionRejections)
            counter("writes fenced", model.diagnostics.fencedWriteRejections)
        }
    }

    private var logCard: some View {
        card("What happened") {
            if model.log.isEmpty {
                Text("No activity yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // `ForEach` over an `Identifiable` collection -- no index arithmetic
                // and therefore no way to read out of bounds.
                ForEach(model.log) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(symbol(for: entry.kind))
                            .font(.caption)
                            .frame(width: 16)
                        Text(entry.text)
                            .font(.caption)
                            .foregroundStyle(colour(for: entry.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func card(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func counter(_ label: String, _ value: Int) -> some View {
        LabeledContent(label) {
            Text("\(value)").font(.caption.monospaced())
        }
        .font(.caption)
    }

    private func symbol(for kind: LeaseTheatreModel.LogEntry.Kind) -> String {
        switch kind {
        case .granted: return "+"
        case .stolen: return "~"
        case .refused: return "x"
        case .written: return ">"
        case .fenced: return "!"
        case .note: return "·"
        }
    }

    private func colour(for kind: LeaseTheatreModel.LogEntry.Kind) -> Color {
        switch kind {
        case .granted, .written: return .primary
        case .stolen: return .blue
        case .refused: return .orange
        case .fenced: return .red
        case .note: return .secondary
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview {
    LeaseTheatreView()
}
#endif
