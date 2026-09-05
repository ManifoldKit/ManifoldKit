## What does this change?

<!-- One paragraph summary -->

## Motivation

<!-- Why is this change needed? Link to any relevant issues with "Closes #123" -->

## Release Note

<!-- For feat: and fix: PRs, draft the release-note fragment here in the
     Prisma-style format used by ManifoldKit since v0.11.2. This gets copied
     into CHANGELOG.md at release time, so write it like a reader sees it.

     For a HEADLINE feature (new subsystem, cross-cutting change, API
     consumers need to know about), use this shape:

         #### Short verb-led headline

         2–3 sentences: the problem, what shipped, how it fits together.

         ```swift
         // 4–8 lines showing the new API in use
         ```

         One more sentence of caveats, opt-in/out semantics, or "see [#N]".

     For a SMALL feature or fix, one bullet is enough — match the style
     of the Features/Fixes sections in CHANGELOG.md:

         - **scope:** what changed — why it matters ([#N])

     For chore/test/docs PRs, write "N/A". -->

## Testing

<!-- State the commands, results, and tested revision. AGENTS.md's Running tests
     and Pre-push checklist define the current gate; note any live verification
     and consumer builds relevant to this change. -->

## Verification evidence

<!-- Follow the existing Test conventions and Draft-PR review loop in AGENTS.md.
     Useful evidence: the caller-visible invariant; a limit or failure scenario;
     a demonstrated-red fixture or log and restored-green result; and the final
     stored state or outstanding work when the operation reports completion.
     For a gate change, include evidence that the check fires and blocks.
     These prompts help explain the evidence; they do not replace those rules. -->

## Checklist

- [ ] Tests added or updated for new behaviour
- [ ] Public API changes have `///` doc comments
- [ ] No hardcoded secrets, API keys, or personal data
- [ ] Breaking change? (if yes, describe migration path below)

## DX checklist

- [ ] Did this change or REMOVE a public API? If yes, `grep -rn '<SymbolName>' README.md AGENTS.md docs/ Sources/**/*.docc/` and updated every doc that names it — not just the README. (A removal with a stale doc is how `docs/QUICKSTART-VOICE.md` advertised the deleted wake-word subsystem for five weeks; `DocClaimsAuditTest` now fails on it, but the grep is faster than a CI round-trip.)
- [ ] Did this add or change a trait, backend, or capability? If yes, updated `Sources/ManifoldKit/FeatureMatrix.swift` (when present).
- [ ] Is this a breaking change for an existing consumer? If yes, added a migration note to `CHANGELOG.md` or `docs/`.
- [ ] Did this change the `quickStart()` path or `MinimalExample`? If yes, the example still compiles and runs end-to-end.
- [ ] Did this introduce a new public error type or surface? If yes, it conforms to `LocalizedError` with a user-facing `errorDescription`.
