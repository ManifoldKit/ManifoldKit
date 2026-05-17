import Foundation
import Observation
import os

/// Public, framework-owned summary of in-flight network activity.
///
/// Consumer apps that surface a "is ManifoldKit talking to the network right
/// now?" indicator (status pill, trust sheet, settings light) bind to
/// ``NetworkActivityCenter/shared`` instead of building a parallel observer
/// that drifts away from MK's actual networking the moment a new code path
/// (manifest fetch, resume probe, HEAD check) is added inside MK.
///
/// The center is a strict superset of `BackgroundDownloadManager.activeDownloads`:
/// it also reports HuggingFace metadata fetches, redirect / probe traffic, and
/// any future generic data-task that flows through ``URLSessionFactory``.
public enum NetworkActivity: Sendable, Equatable {

    /// No active network traffic.
    case idle

    /// A short-lived probe / HEAD-check is in flight.
    case probing(host: String)

    /// A model download is making progress.
    ///
    /// - Parameters:
    ///   - modelID: The owning ``DownloadableModel/id``.
    ///   - bytesReceived: Bytes transferred so far across all files in the
    ///     download.
    ///   - totalBytes: Total expected bytes when the manifest is known;
    ///     `nil` while the server hasn't reported a `Content-Length`.
    ///   - throughputBytesPerSecond: Rolling mean throughput over the last
    ///     measurement window.
    case downloading(
        modelID: String,
        bytesReceived: Int64,
        totalBytes: Int64?,
        throughputBytesPerSecond: Double
    )

    /// A metadata-style fetch (search, repo listing, manifest read) is in
    /// flight against `host`.
    case fetchingMetadata(host: String)
}

/// Classifier for a single in-flight unit of network work.
///
/// Promoted to the public surface so external consumers (CLI tools, alternate
/// download orchestrators) that need to plug into the center can describe
/// their traffic without reaching into MK internals.
public enum NetworkActivityKind: Sendable, Equatable {
    case probe
    case metadata
    case download(modelID: String)
    case generic
}

/// Opaque handle returned by ``NetworkActivityCenter/begin(kind:host:)``.
///
/// Callers retain the token for the lifetime of the request and pass it to
/// ``NetworkActivityCenter/end(_:)`` (or `updateDownload`) so the center can
/// distinguish overlapping calls. The token is intentionally `Sendable` and
/// value-typed so it can cross actor boundaries without ceremony.
public struct NetworkActivityToken: Sendable, Hashable {
    internal let id: UUID
    internal init(id: UUID = UUID()) {
        self.id = id
    }
}

/// `@Observable @MainActor` source of truth for live network activity.
///
/// Bind from SwiftUI via the shared singleton:
///
/// ```swift
/// import ManifoldInference
///
/// struct NetworkPill: View {
///     @State private var center = NetworkActivityCenter.shared
///     var body: some View {
///         switch center.current {
///         case .idle:                       EmptyView()
///         case .probing(let host):          Label("Probing \(host)", systemImage: "antenna.radiowaves.left.and.right")
///         case .downloading(_, let got, let total, _):
///             ProgressView(value: Double(got), total: Double(total ?? got))
///         case .fetchingMetadata(let host): Label("Fetching from \(host)", systemImage: "icloud.and.arrow.down")
///         }
///     }
/// }
/// ```
///
/// Non-SwiftUI consumers can drive a stream via ``updates()``.
///
/// ## Funnel points
///
/// - ``URLSessionFactory/ephemeral(hopCap:resourceTimeout:additionalDataDelegate:activityCenter:)``
///   and ``URLSessionFactory/background(identifier:hopCap:additionalDownloadDelegate:activityCenter:)``
///   wire a tracking delegate that emits begin/end for every data + download
///   task that flows through the factory.
/// - `BackgroundDownloadManager` (in `ManifoldHuggingFace`) overrides the
///   delegate-driven entries with rich per-model download state.
/// - `HuggingFaceService` wraps SDK calls that bypass `URLSessionFactory`.
///
/// ## Concurrency
///
/// State is `@MainActor`-isolated. Off-actor callers (URLSession delegate
/// queue, SDK callbacks) hop in via `Task { @MainActor in ... }`. The center
/// itself never touches the network — it is a passive aggregator.
@Observable
@MainActor
public final class NetworkActivityCenter {

    /// Shared process-wide instance. ``URLSessionFactory`` and
    /// `BackgroundDownloadManager` route activity here by default.
    ///
    /// The reference itself is immutable, so non-isolated callers can read
    /// `.shared` to pass into a factory; every *method* on the returned
    /// instance remains `@MainActor`-isolated.
    public nonisolated(unsafe) static let shared = NetworkActivityCenter()

    /// Current coalesced activity. ``NetworkActivity/idle`` when no requests
    /// are in flight. When several tasks are active, downloads win over
    /// metadata, which wins over probes — the integrator's status indicator
    /// should reflect the most user-visible work first.
    public private(set) var current: NetworkActivity = .idle

    /// Number of in-flight requests across all kinds.
    public var inFlightCount: Int { entries.count }

    /// Distinct hostnames currently in flight, sorted for stable rendering.
    public var activeHosts: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries.values where !entry.host.isEmpty {
            if seen.insert(entry.host).inserted {
                result.append(entry.host)
            }
        }
        return result.sorted()
    }

    private struct Entry {
        let kind: NetworkActivityKind
        let host: String
        var bytesReceived: Int64
        var totalBytes: Int64?
        var throughput: Double
        var lastSampleAt: Date
        var lastSampleBytes: Int64
    }

    private var entries: [UUID: Entry] = [:]

    /// Continuations for ``updates()``. Stored in a dictionary so each
    /// subscriber can clean up independently when its `Task` is cancelled.
    private var subscribers: [UUID: AsyncStream<NetworkActivity>.Continuation] = [:]

    /// Designated initialiser. Public so test suites can spin up isolated
    /// centers without relying on the shared singleton.
    ///
    /// Marked `nonisolated` so the `static let shared` initialiser can run
    /// at process start without hopping to `@MainActor`. All mutation API
    /// on the resulting instance remains `@MainActor`-isolated.
    public nonisolated init() {}

    // MARK: - Tracking API

    /// Records the start of a new in-flight request and returns a token to
    /// pair with ``end(_:)``.
    @discardableResult
    public func begin(kind: NetworkActivityKind, host: String) -> NetworkActivityToken {
        let token = NetworkActivityToken()
        entries[token.id] = Entry(
            kind: kind,
            host: host,
            bytesReceived: 0,
            totalBytes: nil,
            throughput: 0,
            lastSampleAt: Date(),
            lastSampleBytes: 0
        )
        recomputeCurrent()
        return token
    }

    /// Records the end of a previously-begun request. Safe to call with a
    /// stale token — unknown tokens are ignored, which makes
    /// "begin from delegate / end from cancel" races a no-op rather than a
    /// crash.
    public func end(_ token: NetworkActivityToken) {
        guard entries.removeValue(forKey: token.id) != nil else { return }
        recomputeCurrent()
    }

    /// Updates byte counters for a download token and refreshes throughput.
    public func updateDownload(
        _ token: NetworkActivityToken,
        bytesReceived: Int64,
        totalBytes: Int64?
    ) {
        guard var entry = entries[token.id] else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(entry.lastSampleAt)
        // Throughput is sampled on every progress callback. Skip the divide
        // when elapsed time is below 50ms — the resulting figure would be
        // dominated by jitter from the URLSession delegate queue cadence.
        if elapsed >= 0.05 {
            let delta = max(0, bytesReceived - entry.lastSampleBytes)
            entry.throughput = Double(delta) / elapsed
            entry.lastSampleAt = now
            entry.lastSampleBytes = bytesReceived
        }
        entry.bytesReceived = bytesReceived
        entry.totalBytes = totalBytes
        entries[token.id] = entry
        recomputeCurrent()
    }

    // MARK: - Subscriber API

    /// Async stream of state transitions. Emits the current state once on
    /// subscribe so late observers don't miss in-flight activity.
    public func updates() -> AsyncStream<NetworkActivity> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.subscribers.removeValue(forKey: id)
                }
            }
        }
    }

    // MARK: - Internals

    private func recomputeCurrent() {
        let next = computeCurrent()
        guard next != current else { return }
        current = next
        for continuation in subscribers.values {
            continuation.yield(next)
        }
    }

    private func computeCurrent() -> NetworkActivity {
        if entries.isEmpty { return .idle }

        // Prefer the most user-visible in-flight work: an active download
        // dominates a metadata fetch dominates a probe. Within downloads we
        // pick the entry with the highest `bytesReceived` so the indicator
        // tracks the largest live transfer.
        var bestDownload: Entry?
        var bestMetadata: Entry?
        var bestProbe: Entry?
        for entry in entries.values {
            switch entry.kind {
            case .download:
                if bestDownload == nil || entry.bytesReceived > (bestDownload?.bytesReceived ?? -1) {
                    bestDownload = entry
                }
            case .metadata:
                bestMetadata = bestMetadata ?? entry
            case .probe:
                bestProbe = bestProbe ?? entry
            case .generic:
                // Generic data traffic shows up as a metadata-style hint —
                // hosts are still meaningful for a trust UI.
                bestMetadata = bestMetadata ?? entry
            }
        }
        if let download = bestDownload, case .download(let modelID) = download.kind {
            return .downloading(
                modelID: modelID,
                bytesReceived: download.bytesReceived,
                totalBytes: download.totalBytes,
                throughputBytesPerSecond: download.throughput
            )
        }
        if let metadata = bestMetadata {
            return .fetchingMetadata(host: metadata.host)
        }
        if let probe = bestProbe {
            return .probing(host: probe.host)
        }
        return .idle
    }
}
