# Testing & CI Principles

A first-principles framework for how we test and run CI for an SDK like ManifoldKit. These were derived from fresh research into testing/CI practice, reduced to their underlying drivers, then adversarially stress-tested by a panel of critics (epistemology, practice, economics, reduction). The corrections from that review are baked in.

**How to read this.** Each principle states the rule, then names the *driver* it serves — and, where the rule is contingent on a fact that can change, its *expiry condition* (when to stop obeying it). Hold the drivers, not the rules: when a situation is new, re-derive the move from the driver instead of looking up a principle. The principles are peers — when two conflict, drop to their drivers and let the current facts arbitrate.

---

## 1. Verification has two irreducible roots: specification and confidence-under-cost

Every testing decision serves one of two things that do not reduce to each other. **Specification** — what does "correct" even mean here? — is normative and supplied only by a human; no amount of sampling or compute produces it. **Confidence-under-cost** — given a spec, how much warrant do we have that the code meets it, and what did that warrant cost? — is a decision under uncertainty (expected loss = warrant × cost-of-being-wrong). Most "where do I put this test" arguments are really confusion about which root you're serving. The automation boundary falls exactly here: machines verify conformance (*is* the code correct against a spec), humans own specification (*what should* be correct). Automate verification; reserve human judgment for specification, breaking-change intent, and "is this a flake or a real regression."

## 2. Choose the verification *mode* before you write the test

A universal claim ("this works for all inputs") can be established three structurally different ways, and picking the wrong one is the most expensive mistake in the suite. **Deductive** — types, exhaustive `switch`, Swift 6 concurrency proofs — covers the entire input space, paid once, with zero samples. **Inductive** — tests — samples a finite set and generalizes. **Adversarial** — security, supply-chain — must hold against an optimizing attacker, not random variance. Architecture *is* mode selection. Before writing a test, ask which mode the claim wants; reaching for induction by reflex is how a state machine ends up with twelve table-driven tests that an exhaustive enum would have made unrepresentable.

## 3. Prefer deduction — prove the universal in the type system and you never sample it

When the compiler can make an illegal state unrepresentable, that is a universal proven for *all* inputs, for free, forever — categorically stronger and cheaper than any number of inductive tests. Push correctness into types, exhaustive enums, non-optionals, and strict-concurrency checks first; write tests only for what the type system cannot prove. This is why we "validate at system boundaries only — don't guard internal invariants the type system already enforces." The highest-leverage refactor is often *deleting* tests by making their failure mode uncompilable.

## 4. Treat security and supply-chain as adversarial, not statistical

An attacker is not entropy. Entropy is random and samplable; an adversary reads where you looked and targets the complement, so you cannot sample your way to "no exploit exists." Provenance, signing, dependency pinning, and reproducible builds are not economic optimizations or extra tests — they are the *adversarial* mode of verification, and they belong on every release because we are a supply-chain upstream: one tampered artifact fans out to every consumer.

## 5. Test through the public API — it is both the contract and the population you are inferring about

For an SDK, the public API is simultaneously the unit of test, the unit of versioning, and the contract with consumers — they coincide. Test *behavior* at that surface, not internal structure, and keep at least one test target that imports you exactly as a stranger would (plain `import`, public symbols only). Tests coupled to internals stay green while the public API breaks, and they make pure refactors expensive — which trains people to stop refactoring. Enforce semantic versioning mechanically by diffing the public surface against a baseline, with an explicit allowlist for intended breaks.

## 6. Determinism is the lever that makes a finite suite mean anything

A non-deterministic test tells you only about the run that just happened; to generalize you would need infinite runs. Determinism collapses that — one run stands in for all future runs of the same code — which is what makes a *finite* suite valid at all. So hermeticity (no real network, injected clock, injected RNG, isolated global state) is the single highest-leverage technique, but it is a *lever against uncontrolled entropy at your boundaries*, not a first principle in its own right. It earns its primacy by being the thing every other inductive guarantee rests on. *Driver:* boundary entropy. *Note:* determinism collapses the entropy dimension, not the coverage dimension — you still haven't run all inputs.

## 7. Trust is the gate; nothing downstream has value without it

The product of a test suite is not "green checks" — it is a calibrated trust that converts a red signal into action. Trust is a path-dependent capital stock with an *absorbing failure state*: flaky reds train people to ignore the suite, after which even true reds no longer convert to fixes and you pay to run tests that yield negative value (false confidence). The loop is bistable and recovery is slow — you must re-earn trust over many green runs. This is why flakiness is categorically worse than slowness: slowness is a linear cost, flakiness poisons the channel. Guard signal integrity above raw coverage. *Caveat:* a suite at 70% trust is degraded-but-positive; "worse than nothing" is only true once it falls into the lower attractor.

## 8. Tier by severity-weighted value of information, not by cost-per-bug

Place each check where it buys the most *risk reduction* per dollar, not where it catches the most *bugs* per dollar — a single data-loss bug outranks a hundred cosmetic ones, and a bug a later tier would have caught anyway has near-zero value here. Bias toward a wide base of fast, deterministic, mocked tests on every PR; gate expensive real-model / real-network / fuzz tests behind explicit flags on a nightly tier. The two tiers test different things: the hermetic tier carries *correctness of your code*, the gated real tier carries *currency against an upstream world you don't control*. Don't pay for currency on every PR.

## 9. Batch work to an interior optimum, not "as large as possible"

On premium runners (macOS bills ~10×) a fixed cold-build floor is paid per run, so amortizing it over a batch lowers cost — but only up to a point. This is a setup-cost lot-sizing problem (EOQ), and total cost is U-shaped: batch size also *raises* the rerun tax (a batch of n independent changes fails with probability `1−(1−p)ⁿ`), degrades review catch-rate past a few hundred lines of diff, and adds queueing delay. The optimum `B* ≈ √(2DS/H)` shrinks as caching cuts the setup cost S, but it never reaches "infinitely big." *Expiry / caveat:* batching is multi-causal — review economics, semantic-conflict risk, bisectability, and the absence of an org merge queue all push on PR size. Better caching relaxes only the build-floor term; do not fan back out to per-change PRs the moment a cache lands.

## 10. The deliverable is change-confidence — so measure it, don't sloganize it

The asset a suite produces is the confidence to change code without fear. Stated as a slogan ("green checks aren't the point") it licenses deleting "brittle" tests that were catching real regressions, so make it a number: mutation score (does the suite actually fail when behavior breaks?) and escaped-defect rate. A sabotage check — confirm the test fails when the code path breaks — is the per-test instance of this. Optimize the suite's *severity* (would it catch a real break?), not its coverage percentage.

## 11. Add a layer; don't flip a rule

Verification needs stratify, they don't switch. When you start owning a dependency you previously mocked, you *add* a thin real-integration layer and *keep* the fast deterministic mocks for unit speed — nothing "flipped." When you find a genuine three-way configuration bug, you add that one regression case and keep sampling the rest of the matrix. Framing changes as binary rule-flips ("the mock expired") flattens the test pyramid and tends to delete the fast layer that was carrying determinism.

## 12. The cost of a defect tracks accumulated dependency commitment, not elapsed time

A bug gets expensive in proportion to how much dependent, hard-to-reverse work has been built on top of it before detection — not simply how long it sat there. A dormant bug in a leaf module stays cheap; a bug that quickly acquires many dependents (or ships in a release consumers integrate against) is expensive almost immediately, because fixing it is now itself a breaking change. Optimize for catching defects *before the next irreversible commitment*, not merely "early." This is why SDKs have a steeper gradient than apps: each release accretes consumer commitment fast and irreversibly.

## 13. Your test space is discovered, not known — so encode every escaped defect

The configuration/input space has an enumerable part (traits × platforms × backends) you can sample deliberately, and an unknowable part you only learn about by being hurt. You cannot compute the ideal suite up front; the reactive loop — when a bug escapes, add the test that would have caught it — is principled active learning over an unknown space, not a sign of laziness. Treat every production or CI escape as a permanent addition to the known space. The enumerable part justifies a small boundary/pairwise config matrix (bugs cluster at low-order interactions, so pairwise coverage captures most defect mass cheaply); the discovered part justifies the ever-growing regression set.

## 14. Prove a stranger can consume you

A green internal suite does not prove a downstream app can import and build against your published artifact across the ownership boundary — the one place your CI is structurally blind. A separate cold-start consumer package that depends on you as an external client, using only public products, is the only sample that crosses that boundary; it catches accidentally-internal symbols, missing re-exports, broken umbrellas, and trait combinations that fail to link. Compile your README/quick-start examples against the *packaged* form too — a broken first example fails on the consumer's machine where you cannot see it.

## 15. A test double is a frozen assertion about a contract — only fake contracts you own

Every mock encodes a claim: "the real thing behaves like this." If you own the contract, the compiler keeps that claim honest when the contract changes. If a third party owns it (a cloud API, a GPU driver), your mock can silently drift into a lie that passes — green tests, moved reality. So wrap every foreign dependency behind an interface you own, fake *that* for orchestration tests, and verify the real adapter against reality on the gated tier. Prefer state verification (assert what you got back) over interaction verification (assert which calls were made); the former survives refactors.

## 16. Instrument the pipeline itself

You cannot drive down what you do not measure, and the pipeline that manages verification needs verification too. Track the waste directly: CI rerun rate (the retry tax — usually the largest line item on premium runners), flaky-test rate, time-to-green, and signal-to-noise (share of failures that are real bugs; below ~80% the suite is a noise generator and trust is sliding toward the lower attractor). These convert "CI feels expensive" and "the suite feels flaky" into numbers you can act on.
