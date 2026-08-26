# Release Artifacts

Every ManifoldKit release ships supply-chain integrity artifacts in
addition to the source archive. They are produced by
[`.github/workflows/release-provenance.yml`](./.github/workflows/release-provenance.yml)
and signed via [Sigstore](https://www.sigstore.dev/) using the GitHub
Actions OIDC token for this repository — there is no maintainer-held
signing key.

## Artifacts attached to every tag

| Artifact | What it is |
|----------|------------|
| `sbom.cdx.json` | CycloneDX 1.5 SBOM enumerating every Swift package dependency with its pinned git revision and upstream URL. Source: `Package.resolved`. |
| `dependency-tree.json` | `swift package show-dependencies --format json` snapshot taken on the tagged commit. |

Both artifacts have build-provenance attestations recorded in the
public transparency log
([Rekor](https://docs.sigstore.dev/logging/overview/)). The attestation
binds each artifact to:

- the exact commit SHA the tag points at,
- the workflow file that produced it (`release-provenance.yml`), and
- the GitHub repository (`ManifoldKit/ManifoldKit`).

## Verifying a release before pinning

Install the [GitHub CLI](https://cli.github.com/), then:

```bash
TAG=v0.12.2   # replace with the release you want to verify

gh release download "$TAG" \
    --pattern 'sbom.cdx.json' \
    --pattern 'dependency-tree.json' \
    --repo ManifoldKit/ManifoldKit

gh attestation verify sbom.cdx.json \
    --repo ManifoldKit/ManifoldKit \
    --predicate-type https://slsa.dev/provenance/v1

gh attestation verify dependency-tree.json \
    --repo ManifoldKit/ManifoldKit \
    --predicate-type https://slsa.dev/provenance/v1
```

A successful verification proves the file you downloaded is the file
the workflow produced, and that workflow ran on the tagged commit in
this repository.

If verification fails, treat the artifacts as untrusted and open a
security advisory via
[GitHub Security Advisories](https://github.com/ManifoldKit/ManifoldKit/security/advisories/new).

## What the attestations do *not* cover

- The source archive GitHub auto-generates from a tag (`zipball` /
  `tarball`) is not produced by this workflow and is not attested.
  Source-archive provenance and reproducible binary builds are tracked
  under [#714](https://github.com/ManifoldKit/ManifoldKit/issues/714) and
  [#728](https://github.com/ManifoldKit/ManifoldKit/issues/728).
- The attestation does not vouch for upstream dependencies themselves;
  it only asserts that the SBOM accurately enumerates what was pinned
  at tag time. Cross-checking the SBOM's `swift:git-revision` properties
  against upstream tags is left to the consumer.
- Core no longer depends on the `llama.swift` `.xcframework` — the
  llama.cpp family moved to the [manifold-llama](https://github.com/ManifoldKit/manifold-llama)
  companion package in v0.48, so that prebuilt binary blob (and the SHA256
  reproducibility audit scoped by
  [#728](https://github.com/ManifoldKit/ManifoldKit/issues/728)) is now that
  repo's provenance concern, not this SBOM's.

## Regenerating artifacts for an existing tag

If the SBOM generator has a bug fix and you need to refresh artifacts on
an already-published tag without cutting a new release, dispatch the
workflow manually:

```bash
gh workflow run release-provenance.yml --field tag=v0.12.2
```

`gh release upload --clobber` overwrites the previous artifacts and a
fresh attestation is appended to the transparency log.

## Dependency pinning posture

Every dependency is pinned in [`Package.resolved`](./Package.resolved)
by exact git revision. The `Verify Package.resolved is up to date` step
in [`.github/workflows/ci.yml`](./.github/workflows/ci.yml) refuses to
merge a PR that edits `Package.swift` without a corresponding
`Package.resolved` update.

The `ManifoldMacrosPlugin` target builds inside the SwiftPM sandbox
(`sandbox-exec` jail on macOS — no network, restricted filesystem
writes). A CI lint refuses to merge any change that adds `unsafeFlags`,
passes `--disable-sandbox` to `swift build`/`swift test` from a
workflow, or otherwise opts out of the jail. This is the only thing
standing between a compromised macro dependency and exfiltrating local
secrets at compile time.

## Generating an SBOM locally

```bash
./scripts/generate-sbom.sh --output sbom.cdx.json
```

The script reads `Package.resolved` directly, so it is offline and
deterministic — no network access, no SwiftPM resolution required.

## Release runbook

The verified end-to-end sequence for cutting a coordinated ManifoldKit +
companions release. Release Please opens the core release PR automatically
after a `feat:`/`fix:` merge; this runbook covers everything from there.

> **Never edit the release PR's body or title.** Release Please matches its
> own PR by the generated body/title; rewriting either loses that match and
> **breaks the version-tag creation on merge**. Rewrite only `CHANGELOG.md`.

1. **Pre-bump demo gate (mandatory).** Run `scripts/demo-apps-build.sh` — it
   builds both example apps (Advanced iOS, Minimal iOS + macOS) against the
   local package. It **must be green**; do not bump the version if it fails.
   `swift test` builds macOS-only and cannot catch iOS-unavailable symbols
   pulled in via the umbrella, so this is the only gate that catches package
   drift before it ships.

   For a release that claims compatibility with an Apple beta, record the
   Xcode build and select the beta runtime explicitly; the demo script's normal
   destination discovery may otherwise exercise only a stable simulator:

   Set `DEVELOPER_DIR` to the current installed Xcode 27 beta's
   `Contents/Developer` directory, then record the selected toolchain before
   running the gates. Do not reuse evidence from an older beta.

   ```bash
   test -x "$DEVELOPER_DIR/usr/bin/xcodebuild"
   xcodebuild -version
   swift --version
   xcrun simctl list runtimes
   xcrun simctl list devices available
   swift build --build-tests --traits Server,Macros
   scripts/demo-apps-build.sh
   ```

   Record the exact Xcode build, SDK, and iOS 27 simulator UDID in the release
   PR. A macOS 27 SDK compile on a macOS 26 host is compile evidence only; a
   macOS 27 runtime claim requires the same build on a macOS 27 host or VM.

2. **Companion-canary gate — CI-enforced, hard-blocking, no override flag.**
   `.github/workflows/lint.yml`'s `lint` job now runs
   `scripts/companion-canary-check.sh` automatically once it detects a release
   in flight — which needs **both** that `version.txt` is valid SemVer and
   strictly newer than the latest published tag **and** that the change being
   validated modifies `version.txt` itself. The release PR satisfies the second
   condition by construction, so this is invisible here; it exists to stop an
   unrelated PR firing the gates in the window after the release PR merges but
   before `release-please` cuts the tag.

   **It runs on the `pull_request` event only** — in practice, when you push
   the changelog rewrite in step 3 — using `--dispatch`, which triggers fresh
   canary runs on both companions and waits for them. It needs the
   `COMPANION_DISPATCH_TOKEN` repo secret. That PAT needs **Actions: read+write**
   (and contents:read+write) on manifold-mlx / manifold-llama **and
   contents:read on this repository** — the script reads
   `GET /repos/ManifoldKit/ManifoldKit/commits/{sha}/pulls` to resolve when
   `main`'s tip actually landed, and a companion-only PAT fails that preflight
   closed rather than silently falling back to a +60min freshness margin.

   That single run is what blocks: `lint` is a required status check, so the
   release PR cannot be queued until it is green. There is deliberately no
   second check on `merge_group` — freshness there is graded against a main tip
   that moves with every unrelated merge, so it would red the batch for reasons
   having nothing to do with the release (AGENTS.md § "Release workflow" has
   the worked timeline).

   **Sequencing, so this doesn't surprise you:** the dispatch happens when you
   push in step 3, not now, and it can take **up to 45 minutes** (it waits for
   both companion canaries). Budget for that before you expect to run step 4's
   `--auto`. To front-run it, trigger the canaries by hand now and let them
   build while you write the changelog:

   ```bash
   bash scripts/companion-canary-check.sh                # check last known result (fast, may read STALE)
   bash scripts/companion-canary-check.sh --dispatch      # trigger fresh runs and wait (slow, authoritative)
   ```

   A red canary means core moved a seam a companion still depends on. Land the
   companions' adaptation PRs in lockstep (§ "Companion pin-bump releases" in
   AGENTS.md) before continuing — CI will refuse to let the release PR merge
   otherwise.

   **If it reds on STALE rather than FAIL**, the three causes, most to least
   likely: (a) nobody has force-pushed yet, so no dispatch has run — only bot
   changelog regenerations have touched the branch and those never execute
   (AGENTS.md § "Release workflow"); (b) main moved after the canaries were
   dispatched, which re-dispatching fixes; (c) the token could not dispatch at
   all — that now surfaces as a named dispatch error and a non-zero exit, not
   as a STALE reading.

3. **Rewrite the changelog (CHANGELOG.md only).**

   > **If anything merges to `main` while this PR is open, expect to redo this
   > step *and* the canary dispatch.** Release Please regenerates the branch on
   > a new `feat:`/`fix:` (§ "Rewrite last, and merge promptly" below), which
   > force-pushes a new head. Status checks are per-commit, so the green `lint`
   > from your previous push no longer applies, and the regenerated head's own
   > run is bot-actor and therefore never executes — so `lint` never reports and
   > the PR is blocked until you push again. That re-run includes the canary
   > dispatch wait. It stalls rather than bypasses anything, but it is not free:
   > budget another dispatch cycle each time main moves.

   Check out the release
   branch in its worktree (`release-please--branches--main`). CI's
   `changelog-parser-check` (any push, any actor) already re-runs Release
   Please's own commit parser and would have reported a red on this PR if
   it silently dropped a commit (#2380 — its parser can hard-fail on a
   squashed commit body and lose the whole entry with no visible warning);
   check that it's green before proceeding. Optionally cross-check the
   still-generated text directly, before editing anything:

   ```bash
   bash scripts/changelog-coverage-check.sh CHANGELOG.md  # must exit 0, BEFORE rewriting
   ```

   A red here means a merged PR's number doesn't appear anywhere in the
   still-auto-generated section — add the missing entry by hand as part of
   the rewrite below, same as any other bullet. **Only run this check
   against the still-generated section** — once you've rewritten it into
   prose it will flag ordinary, allowed editorial omissions as if they were
   drops; this script is not wired into CI for exactly that reason (see
   AGENTS.md § Release workflow).

   Now rewrite the newest section's auto-generated bullets into
   **Prisma-style Highlights** (`### Highlights` with verb-led headlines,
   2–3 sentences of context, a runnable snippet for new/changed public
   APIs).

   **Flip `docs/MIGRATION-INDEX.md`'s `next` rows to the version being
   shipped.** Every migration note added since the last release lists
   `next` in the Release column (see that file's own header) — replace each
   `next` in a row whose linked note documents a change going out in this
   release with the literal version, e.g. `v0.75.0`. `lint`'s
   `migration-index-gate` step hard-fails the release PR if any row still
   says `next` once a release is detected, so this is not optional. Validate
   locally with:

   ```bash
   bash scripts/migration-index-check.sh --release   # must exit 0
   ```

   Validate the changelog rewrite locally with:

   ```bash
   bash scripts/changelog-lint.sh CHANGELOG.md   # must exit 0
   ```

   Then `git commit --amend` and **force-push** the branch. This is the same
   check CI runs in `.github/workflows/lint.yml`; running it locally avoids a
   red CI round-trip.

4. **Enqueue the release PR.** ManifoldKit `main` **requires the merge
   queue**, so a direct `gh api -X PUT .../pulls/<N>/merge` returns HTTP 405
   ("Changes must be made through the merge queue"). Route it through the
   queue instead and wait for it to actually land:

   ```bash
   gh pr merge <N> --squash --auto        # queues; do NOT use --admin / gh api direct
   gh pr view <N> --json state -q .state   # poll until: MERGED
   ```

   The queue's `lint` job still runs, but the two release gates do **not**
   both re-fire there. `companion-canary-gate` is `pull_request` only (a
   `merge_group` re-check grades freshness against a moving `main` tip and
   ejects the batch). `migration-index-gate --release` **does** run on
   `merge_group`: any `next` row in the tree about to be tagged is a true
   positive, including a note that landed on `main` after the rewrite or
   rode in the same batch. The release PR's own `lint` run is still the
   one that first blocks enqueue (AGENTS.md § "Release workflow").

5. **Verify the tag and post-merge jobs.** Once merged, Release Please pushes
   the version tag and cuts the GitHub release:

   ```bash
   gh release view vX.Y.Z                   # must exist
   gh run list --workflow=release-please.yml --limit 3   # release-please + notify-companions green
   ```

   `sync-release-notes` copies the rewritten CHANGELOG section onto the GitHub
   release; `notify-companions` fires a `core-release` `repository_dispatch` to
   manifold-llama / manifold-mlx / manifold-eval (each dispatch is now
   independent — a single failure no longer blocks the others, and the job
   summary names any that failed for a manual re-dispatch).

6. **Companion releases.**
   - **MINOR bump:** each companion's `core-bump` workflow (triggered by the
     `repository_dispatch`) auto-merges its core-pin PR. Then rewrite + merge
     each companion's own release PR — **llama and mlx have release-please**, so
     they get a tagged release the same way core does. To rewrite a companion
     release PR's notes without hand-authoring, run
     `scripts/companion-release-notes.sh <companion-release-worktree> <mk-version>`
     (inserts a `### Highlights` "Tracks ManifoldKit X.Y" block and preserves any
     extra bullets), then amend + force-push the release branch (CHANGELOG.md only,
     never the PR body). **manifold-eval has no
     release-please and needs no tagged release** (it only re-resolves its
     exact core pin). Companion repos do **not** have a merge queue, so a
     direct `gh api -X PUT .../merge -f merge_method=squash` (or
     `gh pr merge <N> --squash`) still works there.
   - **PATCH bump:** llama/mlx float automatically on their `.upToNextMinor`
     core pin — no companion release needed. Only manifold-eval's exact core
     pin needs a manual bump.
