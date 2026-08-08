import XCTest
import Foundation

/// Audit: the premises behind `companion-compat.yml`'s accepted CodeQL alert
/// must stay true.
///
/// `.github/workflows/companion-compat.yml` carries a checked-in adjudication of
/// CodeQL's `actions/untrusted-checkout/medium` alert, and — this is the part
/// that needs a tripwire — it instructs the next reader to **dismiss** the next
/// recurrence citing that block. The alert re-fingerprints on every
/// `actions/checkout` SHA bump, so recurrences are routine and the instruction
/// will be followed repeatedly.
///
/// The adjudication does not claim the checkout is safe in the abstract. It
/// concedes that fork code *can* reach the job (a maintainer may point
/// `core_ref` at `refs/pull/<N>/head`, and `swift build` then evaluates that
/// ref's `Package.swift`), and accepts it purely on **impact**, resting on four
/// properties of the workflow file:
///
/// 1. `workflow_dispatch` is the only trigger — nothing reaches this job
///    without a deliberate press by someone with write access.
/// 2. `permissions:` grants no more than `contents: read`, on an
///    already-public repo — the token confers nothing an attacker lacks.
/// 3. The runner is GitHub-hosted (`macos-*`), never self-hosted — ephemeral,
///    so there is no persistent host to gain a foothold on.
/// 4. Nothing is cached or uploaded as an artifact — removing the query's real
///    secondary vector, poisoning something a *privileged* workflow consumes.
///
/// Every one of those is a property of a file that anyone may edit, and none
/// was enforced by anything. That is the hazard this audit closes: someone adds
/// an `actions/cache` step to speed up the SwiftPM resolve, or a
/// `workflow_call` trigger so a release workflow can invoke the check, or
/// widens `permissions` to post a status. The prose is now false in exactly the
/// clause that made the alert tolerable — but the *instruction* still says
/// "dismiss it, citing this block", and nobody re-derives an argument that was
/// written down so they wouldn't have to. A genuine finding gets waved through
/// by a stale rationale.
///
/// Per Principle 4, a rule ships with its enforcement or it is not a rule. So:
/// if this audit fails, **do not** relax it to make the build green. Either
/// revert the change to the workflow, or delete the adjudication block and let
/// the alert stand open for a fresh decision. Making the workflow more
/// dangerous and the comment more confident is the one outcome this exists to
/// prevent.
///
/// Deliberate non-goals — a text-level predicate, not a YAML semantic model:
///
/// - A trigger reached through a reusable workflow, or a permission granted by
///   a repo-level default: invisible, because neither is in this file.
/// - **Flow-style YAML.** `on: {workflow_dispatch: null, pull_request_target: null}`
///   puts every trigger on one line and defeats the per-line prefix match.
///   Nobody writes GHA triggers that way and this file does not, so it is named
///   rather than coded around — but it *is* a live bypass, so do not read the
///   block-style coverage as universal.
/// - A hand-rolled cache (`run: tar …` into a shared path) rather than a
///   `cache`-shaped action or input.
/// - **Semantically-identical YAML rewrites red with the wrong reason.** Scalar
///   `on: workflow_dispatch` reports "`workflow_dispatch:` is gone"; flow-form
///   `permissions: {contents: read}` reports "grants every scope". Both are
///   *safe*-direction failures — the audit reds on a file that is fine — but a
///   red carrying a wrong reason is exactly what tempts someone to weaken the
///   check. If you hit one, rewrite the workflow in block style (this repo's
///   form everywhere) rather than relaxing the predicate.
///
/// It covers the four premises the block actually rests on in the form this
/// repo actually writes them, which is what "the adjudication is still sound"
/// requires. It says nothing about whether the alert is *currently* dismissed;
/// that lives in GitHub's state, not the repo.
final class CompanionCompatAdjudicationAuditTest: XCTestCase {

    /// One violated premise, as a human-readable sentence.
    struct Violation: CustomStringConvertible, Equatable {
        let premise: Int
        let detail: String
        var description: String { "premise \(premise): \(detail)" }
    }

    // MARK: - The real audit

    func test_adjudicationPremisesStillHold() throws {
        let workflow = try Self.repoRoot()
            .appendingPathComponent(".github/workflows/companion-compat.yml")
        let text = try String(contentsOf: workflow, encoding: .utf8)

        // Guard against the audit silently passing on a file that moved or was
        // deleted: an empty scan of a missing file is a vacuous green, which is
        // the failure mode this whole file exists to prevent.
        XCTAssertTrue(
            text.contains("actions/untrusted-checkout"),
            """
            companion-compat.yml no longer contains the CodeQL adjudication block. \
            If the block was deliberately removed, delete this audit in the same \
            commit — a premise-checker for an argument nobody makes is noise. If \
            the workflow itself was retired, delete both.
            """
        )

        let violations = Self.premiseViolations(in: text)
        XCTAssertTrue(
            violations.isEmpty,
            """
            companion-compat.yml no longer satisfies the premises its checked-in \
            CodeQL adjudication rests on:
            \(violations.map { "  - \($0)" }.joined(separator: "\n"))

            The adjudication accepts a real untrusted-checkout risk on the grounds \
            of low impact. Whichever premise broke, the acceptance no longer \
            follows. Revert the workflow change, or remove the adjudication block \
            and re-evaluate the alert from scratch — do NOT weaken this audit.
            """
        )
    }

    // MARK: - Detection

    /// Pure predicate over workflow text, so the sabotage test below exercises
    /// the real detection path rather than a replica of it.
    static func premiseViolations(in text: String) -> [Violation] {
        var violations: [Violation] = []
        let lines = text.components(separatedBy: .newlines)

        // Comments carry the adjudication prose, which names the very triggers
        // and actions being banned ("There is no pull_request_target…"). Scan
        // code lines only, or the block would flag itself.
        let code = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        let codeText = code.joined(separator: "\n")

        // Premise 1 — workflow_dispatch is the only trigger.
        for trigger in ["pull_request_target", "workflow_run", "issue_comment",
                        "workflow_call", "schedule", "repository_dispatch"] {
            if code.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(trigger):") }) {
                violations.append(Violation(
                    premise: 1,
                    detail: "`\(trigger)` trigger added — the job is no longer reachable only by a deliberate maintainer press"
                ))
            }
        }
        // `pull_request:` / `push:` need an exact-prefix match so
        // `pull_request_target:` is not double-counted above.
        for trigger in ["pull_request", "push"] {
            if code.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "\(trigger):" }) {
                violations.append(Violation(
                    premise: 1,
                    detail: "`\(trigger)` trigger added — the job is no longer reachable only by a deliberate maintainer press"
                ))
            }
        }
        if !codeText.contains("workflow_dispatch:") {
            violations.append(Violation(
                premise: 1,
                detail: "`workflow_dispatch:` is gone — the adjudication describes a workflow that no longer exists"
            ))
        }

        // Premise 2 — no permission beyond `contents: read`.
        //
        // Anchored to the `permissions:` block, and comment-stripped before
        // matching. Both matter, and an earlier version got both wrong:
        //   * Value-suffix matching (`hasSuffix(": write")`) goes blind the
        //     instant anything follows the value — including a trailing YAML
        //     comment. That is precisely how this repo writes permissions
        //     (`codeql.yml`: `security-events: write   # required to upload
        //     SARIF…`, one of 10 such lines across .github/workflows), so the
        //     single most likely form of the edit this premise guards — a
        //     deliberate widening, annotated with why — was invisible.
        //   * Scanning every line in the file rather than the permissions block
        //     meant a stray `contents: read` anywhere (a step input) satisfied
        //     the positive leg, and any unrelated step input ending `: write`
        //     produced a violation with a wrong diagnosis.
        var sawPermissionsBlock = false
        var grantedScopes: [String: String] = [:]
        var index = 0
        while index < code.count {
            let raw = code[index]
            let trimmed = Self.stripInlineComment(raw)
            guard trimmed == "permissions:" || trimmed.hasPrefix("permissions: ") else {
                index += 1
                continue
            }
            // Anchor on document position, not just the key name. A `permissions:`
            // key can legitimately appear deeper as a third-party action's step
            // input, and keying only on the name means such an input carrying a
            // `contents: read` child would satisfy the positive leg even with the
            // real block deleted — a vacuous green on the premise, which is the
            // worst direction for this audit. Workflow-level permissions sit at
            // indent 0 and job-level at 4; a step input is at 10 or deeper.
            let anchorIndent = raw.prefix { $0 == " " }.count
            guard anchorIndent <= 4 else {
                index += 1
                continue
            }
            sawPermissionsBlock = true

            // Shorthand form: `permissions: write-all` / `read-all` grants every
            // scope on one line. Reported as the explicit grant it is, never as
            // a missing declaration.
            if trimmed.hasPrefix("permissions: ") {
                let value = String(trimmed.dropFirst("permissions: ".count))
                violations.append(Violation(
                    premise: 2,
                    detail: "`permissions: \(value)` grants every scope — the adjudication assumes `contents: read` and nothing else"
                ))
                index += 1
                continue
            }

            // Block form: consume the more-indented lines beneath it.
            let baseIndent = raw.prefix { $0 == " " }.count
            index += 1
            while index < code.count {
                let child = code[index]
                let childIndent = child.prefix { $0 == " " }.count
                guard childIndent > baseIndent else { break }
                let entry = Self.stripInlineComment(child)
                let parts = entry.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2 { grantedScopes[parts[0]] = parts[1] }
                index += 1
            }
        }

        if !sawPermissionsBlock {
            violations.append(Violation(
                premise: 2,
                detail: "no `permissions:` block — the job falls back to the repo default, which can be far broader than `contents: read`"
            ))
        } else {
            for (scope, value) in grantedScopes.sorted(by: { $0.key < $1.key })
            where !(scope == "contents" && value == "read") {
                violations.append(Violation(
                    premise: 2,
                    detail: "permission `\(scope): \(value)` granted — the adjudication assumes `contents: read` and nothing else"
                ))
            }
            if grantedScopes["contents"] == nil && !grantedScopes.isEmpty {
                violations.append(Violation(
                    premise: 2,
                    detail: "`contents: read` is no longer declared in the permissions block"
                ))
            }
        }

        // Premise 3 — GitHub-hosted runner, never self-hosted.
        //
        // Scanned over the whole code text, NOT just `runs-on:` lines. This
        // workflow already has a `strategy.matrix`, so the natural way to add a
        // self-hosted Apple-Silicon runner is `runs-on: ${{ matrix.runner }}`
        // with `runner: [self-hosted, macOS]` in the matrix — where the literal
        // sits lines away from any `runs-on:`. A `runs-on:`-only check misses
        // exactly the shape most likely to occur here (verified: it did).
        if codeText.contains("self-hosted") {
            violations.append(Violation(
                premise: 3,
                detail: "`self-hosted` appears in the workflow — the runner may no longer be ephemeral, so a foothold can persist"
            ))
        }

        // Premise 4 — nothing cached, nothing uploaded.
        //
        // Deliberately broad on both halves, for the same reason as premise 3.
        // Caching is not only `actions/cache`: setup-* actions expose `cache:`
        // inputs that write the same shared store, and an exact `actions/cache`
        // match sails past `swift-actions/setup-swift` with `cache: true`.
        // Likewise `upload-artifact` as a substring misses
        // `actions/upload-pages-artifact`. Both misses were verified before
        // this was widened. A false positive here costs one comment or one
        // deliberate re-evaluation; a false negative costs the whole guard.
        if codeText.range(of: #"(?i)\bcache\b"#, options: .regularExpression) != nil {
            violations.append(Violation(
                premise: 4,
                detail: "caching appears in the workflow — a poisoned cache entry can reach whatever else restores that key. If this is genuinely inert, re-evaluate the alert rather than narrowing this check"
            ))
        }
        if codeText.range(of: #"upload-[a-z-]*artifact"#, options: .regularExpression) != nil {
            violations.append(Violation(
                premise: 4,
                detail: "artifact upload added — a privileged `workflow_run` consumer could ingest attacker-controlled output"
            ))
        }

        return violations
    }

    // MARK: - Sabotage

    /// Plants each of the four premise breaks against the REAL predicate and
    /// asserts it fires — and that the shipped file's own prose, which names
    /// every banned trigger while explaining why they are absent, does not.
    func test_sabotage_premiseBreaksAreDetected() throws {
        let sound = """
        name: Companion compat
        on:
          workflow_dispatch:
            inputs:
              core_ref:
                type: string
        permissions:
          contents: read
        jobs:
          compat:
            runs-on: macos-15
            steps:
              - uses: actions/checkout@abc123
        """

        // The real file must pass, and so must this minimal equivalent —
        // otherwise the audit is green for the wrong reason.
        XCTAssertEqual(Self.premiseViolations(in: sound), [],
                       "A workflow satisfying all four premises must produce no violations")

        // Premise 1: a privileged trigger.
        let p1 = sound.replacingOccurrences(
            of: "  workflow_dispatch:",
            with: "  pull_request_target:\n  workflow_dispatch:"
        )
        XCTAssertTrue(Self.premiseViolations(in: p1).contains { $0.premise == 1 },
                      "A pull_request_target trigger must break premise 1")

        // Premise 2: a widened permission.
        let p2 = sound.replacingOccurrences(
            of: "  contents: read",
            with: "  contents: read\n  packages: write"
        )
        XCTAssertTrue(Self.premiseViolations(in: p2).contains { $0.premise == 2 },
                      "A `packages: write` grant must break premise 2")

        // Premise 2, second shape: permissions dropped entirely.
        let p2b = sound.replacingOccurrences(of: "permissions:\n  contents: read\n", with: "")
        XCTAssertTrue(Self.premiseViolations(in: p2b).contains { $0.premise == 2 },
                      "Dropping the permissions block must break premise 2")

        // Premise 3: a self-hosted runner.
        let p3 = sound.replacingOccurrences(of: "runs-on: macos-15",
                                            with: "runs-on: [self-hosted, macOS]")
        XCTAssertTrue(Self.premiseViolations(in: p3).contains { $0.premise == 3 },
                      "A self-hosted runner must break premise 3")

        // Premise 4: a cache step, and separately an artifact upload.
        let p4a = sound.replacingOccurrences(
            of: "      - uses: actions/checkout@abc123",
            with: "      - uses: actions/checkout@abc123\n      - uses: actions/cache@def456"
        )
        XCTAssertTrue(Self.premiseViolations(in: p4a).contains { $0.premise == 4 },
                      "An actions/cache step must break premise 4")

        let p4b = sound.replacingOccurrences(
            of: "      - uses: actions/checkout@abc123",
            with: "      - uses: actions/checkout@abc123\n      - uses: actions/upload-artifact@def456"
        )
        XCTAssertTrue(Self.premiseViolations(in: p4b).contains { $0.premise == 4 },
                      "An artifact upload must break premise 4")

        // --- Regression cases -------------------------------------------------
        // All three of these passed CLEAN against the first version of this
        // predicate, on the real workflow file. They are the shapes most likely
        // to actually occur here, which is exactly why they are pinned.

        // Premise 3, the realistic shape: this workflow already has a
        // strategy.matrix, so a self-hosted runner arrives via the matrix and
        // the literal never appears on a `runs-on:` line.
        let p3matrix = sound
            .replacingOccurrences(of: "    runs-on: macos-15",
                                  with: "    strategy:\n      matrix:\n        runner: [self-hosted, macOS]\n    runs-on: ${{ matrix.runner }}")
        XCTAssertTrue(Self.premiseViolations(in: p3matrix).contains { $0.premise == 3 },
                      "A self-hosted runner reached through the matrix must break premise 3 — a runs-on-only check misses it")

        // Premise 4: caching without `actions/cache` — a setup-* action's
        // `cache:` input writes the same shared store.
        let p4setup = sound.replacingOccurrences(
            of: "      - uses: actions/checkout@abc123",
            with: "      - uses: swift-actions/setup-swift@abc123\n        with:\n          cache: true"
        )
        XCTAssertTrue(Self.premiseViolations(in: p4setup).contains { $0.premise == 4 },
                      "A setup-action `cache: true` input must break premise 4 — matching only `actions/cache` misses it")

        // Premise 4: `upload-pages-artifact` does not contain the substring
        // `upload-artifact`.
        let p4pages = sound.replacingOccurrences(
            of: "      - uses: actions/checkout@abc123",
            with: "      - uses: actions/upload-pages-artifact@abc123"
        )
        XCTAssertTrue(Self.premiseViolations(in: p4pages).contains { $0.premise == 4 },
                      "`upload-pages-artifact` must break premise 4 — a bare `upload-artifact` substring match misses it")

        // Premise 2, THE case that matters: a widened permission carrying a
        // trailing comment explaining it. This is the house style — 10 such
        // lines across .github/workflows, e.g. codeql.yml's
        // `security-events: write   # required to upload SARIF results…` — so
        // it is the most probable form of the very edit this premise guards,
        // and the value-suffix matcher it replaced was blind to exactly it.
        let p2annotated = sound.replacingOccurrences(
            of: "  contents: read",
            with: "  contents: read\n  packages: write   # needed to push the compat image"
        )
        XCTAssertTrue(Self.premiseViolations(in: p2annotated).contains { $0.premise == 2 },
                      "An annotated `packages: write   # why` must break premise 2 — the house style must not be a blind spot")

        // Premise 2, anchoring: a stray `contents: read` outside any
        // permissions block must NOT satisfy the positive leg.
        let p2stray = sound
            .replacingOccurrences(of: "permissions:\n  contents: read\n", with: "")
            .replacingOccurrences(of: "      - uses: actions/checkout@abc123",
                                  with: "      - uses: actions/checkout@abc123\n        with:\n          contents: read")
        XCTAssertTrue(Self.premiseViolations(in: p2stray).contains { $0.premise == 2 },
                      "A `contents: read` surviving as a step input must not stand in for a permissions block")

        // Premise 2, the inverse: an unrelated step input ending in `: write`
        // must NOT be reported as a permission grant.
        let p2falsePositive = sound.replacingOccurrences(
            of: "      - uses: actions/checkout@abc123",
            with: "      - uses: actions/checkout@abc123\n        with:\n          mode: write"
        )
        XCTAssertEqual(Self.premiseViolations(in: p2falsePositive), [],
                       "A step input `mode: write` outside the permissions block must not be diagnosed as a permission grant")

        // Premise 2, positional anchoring: a `permissions:` key appearing deeper
        // as a step input must NOT stand in for the real block. Keying on the
        // name alone left a vacuous green here.
        let p2nested = sound
            .replacingOccurrences(of: "permissions:\n  contents: read\n", with: "")
            .replacingOccurrences(of: "      - uses: actions/checkout@abc123",
                                  with: "      - uses: third-party/action@abc123\n        with:\n          permissions:\n            contents: read")
        XCTAssertTrue(Self.premiseViolations(in: p2nested).contains { $0.premise == 2 },
                      "A nested `permissions:` step input must not satisfy the anchor once the real block is gone")

        // Premise 2: the grant-everything shorthand must be reported AS such,
        // not as a missing-declaration fallback.
        let p2all = sound.replacingOccurrences(of: "permissions:\n  contents: read",
                                               with: "permissions: write-all")
        let p2allViolations = Self.premiseViolations(in: p2all)
        XCTAssertTrue(p2allViolations.contains { $0.premise == 2 && $0.detail.contains("grants every scope") },
                      "`permissions: write-all` must be reported as an explicit grant, not as a missing declaration; got \(p2allViolations)")

        // The prose guard: the shipped block names `pull_request_target`,
        // `actions/cache` and `upload-artifact` while explaining their absence.
        // If comment lines were scanned, the audit would flag the very file it
        // is defending — a self-defeating tripwire, and an easy regression.
        let prose = """
        # There is no pull_request_target trigger, and no actions/cache or
        # upload-artifact step anywhere in this file.
        \(sound)
        """
        XCTAssertEqual(Self.premiseViolations(in: prose), [],
                       "Comment prose naming the banned constructs must not be flagged")
    }

    // MARK: - Helpers

    /// Drops a trailing YAML comment and surrounding whitespace.
    ///
    /// Values in a `permissions:` block are bare tokens (`read`/`write`/`none`),
    /// never quoted strings containing `#`, so a first-`#` split is exact here.
    static func stripInlineComment(_ line: String) -> String {
        let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return body.trimmingCharacters(in: .whitespaces)
    }

    private static func repoRoot() throws -> URL {
        // This file lives at Tests/ManifoldCoreTests/<this>.swift.
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()  // ManifoldCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
    }
}
