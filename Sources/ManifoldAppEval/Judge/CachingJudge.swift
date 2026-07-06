import Foundation
import CryptoKit
import ManifoldInference

// MARK: - JudgeCacheKey

/// The content-addressed cache key computation for ``CachingJudge``.
///
/// A free-standing, non-generic enum (rather than a static method on
/// `CachingJudge<Underlying>`) so the key derivation is independently
/// testable and has no coupling to whichever `EvalJudge` conformance is
/// wrapped.
public enum JudgeCacheKey {
    /// The SHA-256 hex digest of `request`'s canonical serialization.
    ///
    /// "Canonical" means: a fixed, alphabetically-sorted field list built
    /// explicitly here (not via `JudgeRequest`'s own `Codable`, which this
    /// type doesn't otherwise need) with each field length-prefixed before
    /// concatenation, so two requests can never collide by having their field
    /// boundaries shift (e.g. `candidate: "ab", rubric: "c"` vs.
    /// `candidate: "a", rubric: "bc"`). The result is independent of
    /// `JudgeRequest`'s declaration order or of any particular encoder's
    /// (non-)deterministic key ordering — identical field *values* always
    /// hash identically.
    public static func hash(for request: JudgeRequest) -> String {
        let canonical = canonicalString(for: request)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The canonical (pre-hash) string. Exposed for debugging/testing; the
    /// hash (``hash(for:)``) is what `CachingJudge` actually uses as a
    /// filename.
    static func canonicalString(for request: JudgeRequest) -> String {
        let fields: [String: String] = [
            "id": request.id,
            "content": request.content,
            "candidate": request.candidate,
            "hasReference": request.reference != nil ? "true" : "false",
            "reference": request.reference ?? "",
            "rubric": request.rubric,
        ]
        return fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key.count):\($0.key)=\($0.value.count):\($0.value)" }
            .joined(separator: "|")
    }
}

// MARK: - CachingJudge

/// A content-addressed caching decorator over any ``EvalJudge``.
///
/// Judge calls are typically the most expensive and highest-latency step in
/// an eval run (a real model invocation) — wrapping a real conformer (e.g.
/// fireside's `ClaudeCodeJudge`) in `CachingJudge` means re-running the same
/// fixture twice (a CI re-run, local iteration) costs nothing after the first
/// pass, without the harness spine ever assuming a particular billing model
/// or transport.
///
/// ## Storage
///
/// `directory` is caller-injected — never a hard-coded path, never
/// `UserDefaults` (this repo's standing "inject storage, don't reach for a
/// shared/global default" convention). Each cache entry is one
/// `<sha256>.json` file: ``JudgeVerdict``, JSON-encoded.
///
/// ## Corrupt-entry tolerance
///
/// A cache file that fails to decode (truncated write, schema drift from an
/// older on-disk shape) is treated as a miss, not a crash: the underlying
/// judge is invoked, its verdict overwrites the corrupt file, and a `Log.*`
/// warning records the corruption. Always `do`/`catch` with a warning — never
/// `try?` — matching `SilentCatchAuditTest`'s standing rule.
public struct CachingJudge<Underlying: EvalJudge>: EvalJudge {
    private let underlying: Underlying
    private let directory: URL

    /// No injectable `FileManager` — `FileManager` is not `Sendable`
    /// (documented as safe to share across threads by Apple, but the
    /// compiler can't express that), so a struct can't store one and stay
    /// automatically `Sendable`. `.default` matches the rest of this
    /// module's file I/O (``GoldenTaskLoader``); the injectable seam this
    /// type actually needs is `directory`, which it has.
    public init(underlying: Underlying, directory: URL) {
        self.underlying = underlying
        self.directory = directory
    }

    public func judge(_ request: JudgeRequest) async throws -> JudgeVerdict {
        let file = cacheFile(for: request)

        if let cached = readCache(at: file) {
            return cached
        }

        let verdict = try await underlying.judge(request)
        writeCache(verdict, to: file)
        return verdict
    }

    /// The on-disk location `request` would be cached at, without performing
    /// any I/O. Exposed so tests (and callers debugging a cache miss) can
    /// assert presence/absence directly.
    public func cacheFile(for request: JudgeRequest) -> URL {
        directory.appendingPathComponent("\(JudgeCacheKey.hash(for: request)).json")
    }

    // MARK: - Cache I/O

    private func readCache(at file: URL) -> JudgeVerdict? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let data = try Data(contentsOf: file)
            return try JSONDecoder().decode(JudgeVerdict.self, from: data)
        } catch {
            Log.inference.warning(
                "CachingJudge: corrupt cache entry at \(file.lastPathComponent, privacy: .public), treating as miss: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    private func writeCache(_ verdict: JudgeVerdict, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(verdict)
            try data.write(to: file, options: .atomic)
        } catch {
            Log.inference.warning(
                "CachingJudge: failed to write cache entry at \(file.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
