import XCTest
import ManifoldAppEval

// MARK: - CachingJudgeTests

/// Cache hit/miss/corrupt-entry behavior and canonical-hash stability for
/// ``CachingJudge`` / ``JudgeCacheKey``.
final class CachingJudgeTests: XCTestCase {

    private var cacheDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("caching-judge-tests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        if let cacheDirectory {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        try await super.tearDown()
    }

    private func request(id: String = "fixture#checkpoint") -> JudgeRequest {
        JudgeRequest(id: id, content: "scene text", candidate: "candidate json", reference: "reference json", rubric: "grade it")
    }

    // MARK: - Miss then hit

    func test_miss_thenHit_invokesUnderlyingOnlyOnce() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 0.9, rationale: "close enough"))
        let caching = CachingJudge(underlying: judge, directory: cacheDirectory)
        let req = request()

        let first = try await caching.judge(req)
        XCTAssertEqual(first.score, 0.9)
        let firstCallCount = await judge.callCount
        XCTAssertEqual(firstCallCount, 1)

        let second = try await caching.judge(req)
        XCTAssertEqual(second, first, "a cache hit must return byte-identical content to the original verdict")
        let secondCallCount = await judge.callCount
        XCTAssertEqual(secondCallCount, 1, "a cache hit must never re-invoke the underlying judge")
    }

    func test_differentRequests_bothInvokeUnderlying() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 0.5, rationale: "n/a"))
        let caching = CachingJudge(underlying: judge, directory: cacheDirectory)

        _ = try await caching.judge(request(id: "a"))
        _ = try await caching.judge(request(id: "b"))

        let callCount = await judge.callCount
        XCTAssertEqual(callCount, 2, "distinct requests must not collide in the cache")
    }

    // MARK: - Corrupt-entry tolerance

    func test_corruptCacheEntry_treatedAsMiss_thenOverwritten() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 0.8, rationale: "recovered"))
        let caching = CachingJudge(underlying: judge, directory: cacheDirectory)
        let req = request()

        // Plant a corrupt entry at the exact path this request would hash to.
        let file = caching.cacheFile(for: req)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try Data("not valid json {{{".utf8).write(to: file)

        let verdict = try await caching.judge(req)
        XCTAssertEqual(verdict.score, 0.8, "a corrupt entry must be treated as a miss, not thrown")
        let callCount = await judge.callCount
        XCTAssertEqual(callCount, 1)

        // The corrupt entry should now be overwritten with a valid one.
        let data = try Data(contentsOf: file)
        let decoded = try JSONDecoder().decode(JudgeVerdict.self, from: data)
        XCTAssertEqual(decoded.score, 0.8)
    }

    // MARK: - Canonical hash stability

    func test_canonicalHash_stableAcrossRepeatedComputation() {
        let req = request()
        let key1 = JudgeCacheKey.hash(for: req)
        let key2 = JudgeCacheKey.hash(for: req)
        XCTAssertEqual(key1, key2)
    }

    /// Two independently-constructed requests with identical field *values*
    /// (built via different code paths / argument orderings, the only
    /// "ordering" a fixed-shape struct admits) must hash identically — the
    /// canonicalization must not depend on construction order.
    func test_canonicalHash_sameFieldValues_sameKey_regardlessOfConstructionPath() {
        let a = JudgeRequest(id: "x", content: "c", candidate: "cand", reference: "ref", rubric: "r")
        // Constructed via a different route (defaulted then explicit
        // re-derivation) to prove the hash is a pure function of field
        // values, not of how the struct got built.
        let fields = (id: "x", content: "c", candidate: "cand", reference: Optional("ref"), rubric: "r")
        let b = JudgeRequest(id: fields.id, content: fields.content, candidate: fields.candidate, reference: fields.reference, rubric: fields.rubric)

        XCTAssertEqual(a, b)
        XCTAssertEqual(JudgeCacheKey.hash(for: a), JudgeCacheKey.hash(for: b))
    }

    func test_canonicalHash_differsWhenAnyFieldDiffers() {
        let base = JudgeRequest(id: "x", content: "c", candidate: "cand", reference: "ref", rubric: "r")
        let differentCandidate = JudgeRequest(id: "x", content: "c", candidate: "cand2", reference: "ref", rubric: "r")
        let differentReference = JudgeRequest(id: "x", content: "c", candidate: "cand", reference: nil, rubric: "r")

        XCTAssertNotEqual(JudgeCacheKey.hash(for: base), JudgeCacheKey.hash(for: differentCandidate))
        XCTAssertNotEqual(JudgeCacheKey.hash(for: base), JudgeCacheKey.hash(for: differentReference))
    }

    /// Field-boundary collision guard: concatenating `candidate` and `rubric`
    /// without a length-prefixed delimiter could make `("ab", "c")` hash the
    /// same as `("a", "bc")`. The length-prefixing in
    /// `JudgeCacheKey.canonicalString(for:)` must prevent that.
    func test_canonicalHash_noFieldBoundaryCollision() {
        let shifted1 = JudgeRequest(id: "x", content: "", candidate: "ab", reference: nil, rubric: "c")
        let shifted2 = JudgeRequest(id: "x", content: "", candidate: "a", reference: nil, rubric: "bc")
        XCTAssertNotEqual(JudgeCacheKey.hash(for: shifted1), JudgeCacheKey.hash(for: shifted2))
    }
}
