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

    func test_differentContent_bothInvokeUnderlying() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 0.5, rationale: "n/a"))
        let caching = CachingJudge(underlying: judge, directory: cacheDirectory)

        var second = request()
        second = JudgeRequest(id: second.id, content: second.content, candidate: "different candidate", reference: second.reference, rubric: second.rubric)
        _ = try await caching.judge(request())
        _ = try await caching.judge(second)

        let callCount = await judge.callCount
        XCTAssertEqual(callCount, 2, "content-distinct requests must not collide in the cache")
    }

    /// The `id` is a diagnostic label, not content: two requests identical
    /// in every content field but differing in `id` (e.g. a renamed fixture
    /// or two checkpoints grading identical content) must share one cache
    /// entry — the second call is a hit, never a re-bill.
    func test_idIsExcludedFromCacheKey_renamedRequestHitsCache() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 0.6, rationale: "cached"))
        let caching = CachingJudge(underlying: judge, directory: cacheDirectory)

        let original = request(id: "old-fixture#checkpoint")
        let renamed = request(id: "renamed-fixture#other-checkpoint")
        XCTAssertEqual(JudgeCacheKey.hash(for: original), JudgeCacheKey.hash(for: renamed))

        _ = try await caching.judge(original)
        let second = try await caching.judge(renamed)
        XCTAssertEqual(second.score, 0.6)

        let callCount = await judge.callCount
        XCTAssertEqual(callCount, 1, "an id-only difference must be a cache hit, not a re-bill")
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

    func test_canonicalHash_differsWhenAnyContentFieldDiffers() {
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
