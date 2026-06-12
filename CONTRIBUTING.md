# Contributing to ManifoldKit

Thank you for your interest in contributing.

This guide is **indexed by change type** — find the section that matches the change
you're making and follow the gates listed there. Cross-references point at
[CLAUDE.md](CLAUDE.md), the authoritative dev reference, rather than duplicating it.

## Table of contents

- [Getting started](#getting-started)
- [Architecture invariants](#architecture-invariants) — read **before** moving
  imports between modules
- [Pre-push checklist](#pre-push-checklist) — run **every** time, regardless of
  change type
- [Adding a new backend](#adding-a-new-backend)
- [Adding a UI view](#adding-a-ui-view)
- [Adding a dependency](#adding-a-dependency)
- [Adding a network feature](#adding-a-network-feature)
- [Adding a macro](#adding-a-macro)
- [Adding a setting / configuration flag](#adding-a-setting--configuration-flag)
- [Commit style](#commit-style)
- [DX budget](#dx-budget) — one `dx:` PR per minor cycle for DX debt
- [Pull request process](#pull-request-process)
- [PR hygiene](#pr-hygiene)
- [Reporting bugs](#reporting-bugs)
- [Reporting security vulnerabilities](#reporting-security-vulnerabilities)
- [License](#license)

## Getting started

```bash
git clone https://github.com/roryford/ManifoldKit.git
cd ManifoldKit
swift build
swift test
```

`swift build` resolves package dependencies on first run. `ManifoldBackends` pulls in
MLX and llama.cpp xcframeworks under default traits, so the initial fetch may take a
moment.

The trait set defaults to `MLX, Llama` (the offline build mode) — see
[SECURITY.md § Supported Build Modes](SECURITY.md#supported-build-modes) for the
four blessed configurations and what each one guarantees.

For repo-developer build-mode workflow (Xcode trait limitations, common mistakes,
the `#warning` stub mechanism), see [CLAUDE.md](CLAUDE.md).
Swift 6 concurrency pitfalls that can compile while racing or deadlocking are
covered in
[CLAUDE.md § Swift 6 concurrency gotchas](CLAUDE.md#swift-6-concurrency-gotchas);
review that section before adding actor-isolated state, async helper closures,
mutable `Sendable` wrappers, streams, detached tasks, or async cleanup.

## Architecture invariants

ManifoldKit's module graph is enforced by lint, not just convention. Four hard
rules must hold for every PR; the
[`TrafficBoundaryAuditTest`](Tests/ManifoldInferenceTests/TrafficBoundaryAuditTest.swift)
suite fails CI if any of them is violated.

1. **`ManifoldUI` never imports `ManifoldBackends`.** UI is a consumer-facing
   chat surface. Backend code carries cloud-SDK weight, MLX/llama.cpp binary
   xcframeworks, and SwiftData adapters (transitively) that have no business
   in the view layer. Inference reaches UI through `ManifoldInference`'s
   service protocols and `ManifoldRuntime`'s ports.

2. **`ManifoldUI` never imports `ManifoldUIModelManagement`.** The dependency
   is one-way: model-management views depend on chat views, not the other way
   around. The cycle is dissolved by closure-injecting `APIConfigurationView`
   via a `@ViewBuilder apiConfiguration:` parameter on `ChatView` — see
   [Building a Chat UI](Sources/ManifoldUI/ManifoldUI.docc/Articles/BuildingAChatUI.md)
   for the canonical wiring.

3. **`ManifoldBackends` and `ManifoldMCP` depend on `ManifoldInference`
   directly, not on `ManifoldRuntime`.** That keeps both modules free of
   SwiftData and free of runtime-port adapters, so host apps can wire backends
   or MCP into a non-SwiftData runtime without dragging the persistence layer
   in transitively.

4. **`ConversationRuntime` is the single turn loop.** Every user-facing chat
   action — send, regenerate, edit, cancel, branch — routes through
   `ConversationRuntime` via `processTurn(TurnInput(...))`. There is no
   alternative path. New features that touch turn flow extend
   `ConversationRuntime`; they must not call `InferenceService` directly from
   the UI layer.

If a PR genuinely needs to cross one of these boundaries, the fix is almost
always to promote a protocol downward (into `ManifoldInference`) or extract a
new port (into `ManifoldRuntime`) — never to add the reverse import. Reviewers
will push back on `// swiftlint:disable` style escape hatches in the audit
allowlists; the cap on each allowlist is intentionally low.

`TrafficBoundaryAuditTest` is one of 19 audit tests in the repo. For the wider
pattern — how audit tests work, when to add a new one, the sabotage suite that
keeps them honest, plus DX walkthroughs and cold-start conformance gates — see
[`docs/QA-PRACTICES.md`](docs/QA-PRACTICES.md).

## Pre-push checklist

**Run before every push.** CI is macOS-only with a 10× billing multiplier; each
failed push wastes ~25 billed minutes.

```bash
scripts/test.sh --profile local
```

Use `scripts/test.sh` as the source of truth for the gate shape: it preserves the
required two-invocation split between XCTest and Swift Testing. When you're
reproducing a CI-only failure locally, use `scripts/test.sh --profile ci`.

Never push based on a subset passing. After rebasing, always re-run the full suite —
conflicts can silently break tests that compiled fine before.

When changing the behaviour of any function or type, grep the entire `Tests/`
directory for references — not just the obvious test file:

```bash
grep -r "functionOrTypeName" Tests/
```

See [CLAUDE.md](CLAUDE.md) for the canonical test conventions, hardware constraints,
and the `withKnownIssue` policy.

## Adding a new backend

A backend is anything that conforms to `InferenceBackend` and gets registered with
`InferenceService`.

1. **Pick the right home** for the file. Local backends are trait-gated:
   - `MLX` — Apple Silicon MLX backend (`Sources/ManifoldMLX`, wrap in `#if MLX`).
   - `Llama` — llama.cpp / GGUF (`Sources/ManifoldLlama`, wrap in `#if Llama`).

   Cloud backends are **not** trait-gated since v0.48 — they live in
   `Sources/ManifoldOllama` / `Sources/ManifoldCloudSaaS` (shared HTTP/SSE
   infra in `Sources/ManifoldCloudCore`) and compile unconditionally;
   consumers exclude them by not linking the products.

2. **Register via `DefaultBackends.register(with:)`** rather than calling backend
   constructors from app code. The registration helper handles trait gating and
   default-backend wiring; direct constructor calls bypass that and emit
   deprecation warnings.

3. **Update `APIProvider.availableInBuild`** (via `BackendDescriptorRegistry`)
   so the UI provider picker lists the new provider in documented order.

4. **Add tests in `ManifoldBackendsTests`** — with a matching `#if <Trait>`
   only for trait-gated local backends; cloud backend tests are unconditional.

5. **HTTP I/O goes through `URLSessionProvider`.** Direct `URLSession.shared` use
   is banned by `TrafficBoundaryAuditTest` Rule 1. If your backend speaks HTTP,
   it must use `URLSessionProvider` so the runtime kill-switch
   (`URLSessionProvider.networkDisabled`) covers it.

6. **Hostname literals** (`https://api.example.com`) are allowlisted per file by
   the audit's Rule 3 (`allowedHostnameFiles`). If your backend introduces a new
   hostname, add the *file* to the allowlist with a justification comment — not
   the hostname itself, and never inline-suppress the rule.

7. **Run before pushing:**
   ```bash
   swift test --filter ManifoldBackendsTests --disable-default-traits
   swift test --filter ManifoldInferenceTests --disable-default-traits   # for the audit
   ```
   On Apple Silicon, also run `--traits MLX,Llama` so the actual hardware-bound
   tests execute.

See [SECURITY.md § Supported Build Modes](SECURITY.md#supported-build-modes) and
[docs/THREAT_MODEL.md § B1 Network ↔ device](docs/THREAT_MODEL.md#b1-network--device)
for the security context.

## Adding a UI view

UI lives in `ManifoldUI` and (for model-management surfaces) `ManifoldUIModelManagement`.

1. **Don't `import ManifoldBackends` from UI.** This is enforced by
   `TrafficBoundaryAuditTest` Rule 6 (import-graph layering) — the back-edge
   would close a dependency cycle. UI consumes inference via
   `ManifoldInference`'s service protocols.

2. **Cloud-config UI** (anything that talks to `APIEndpoint`, lists API providers,
   or reads/writes Keychain entries) compiles unconditionally since v0.48. If an
   affordance should hide for a given deployment, key it on runtime endpoint
   configuration state — not a compile flag.

3. **Pasteboard writes** must use `localOnly: true` or be added to the
   `privacyAPIAllowlist` with an explicit justification entry. Default
   `UIPasteboard.general` writes broadcast via Continuity — see
   `TrafficBoundaryAuditTest` Rule 4.

4. **Run before pushing:**
   ```bash
   swift test --filter ManifoldUITests --disable-default-traits
   swift test --filter ManifoldUIModelManagementTests --disable-default-traits
   ```

For the UI / framework / host-app trust boundary, see
[docs/THREAT_MODEL.md § B5](docs/THREAT_MODEL.md#b5-ui--framework--host-application).

## Adding a dependency

A new SwiftPM dependency, a new binary xcframework, or a version bump to an existing
dependency.

1. **Pick a trait gate.** If the dependency only matters for one backend or
   feature, gate the `.product(...)` entry with `condition: .when(traits: [...])`.
   Always-on dependencies need a justification in the PR body.

2. **`Package.resolved`** updates are procurement-relevant. The PR description
   should call out any change to `Package.resolved` so downstream consumers can
   match it against their own pin policies.

3. **Binary dependencies** (xcframeworks): note that there is no SHA-256 checksum
   pin today, only revision pinning. Tracked under
   [#714](https://github.com/roryford/ManifoldKit/issues/714) Phase 5 — flag the
   PR for security review.

4. **SwiftPM plugins** (`.buildToolPlugin`, `.commandPlugin`) are **banned** by
   `TrafficBoundaryAuditTest` Rule 5. Plugins run at build time with full
   filesystem + network access; adding one requires explicit security review and
   an audit allowlist update.

5. **`unsafeFlags` and `linkedFramework("Network")` / `linkedFramework("CFNetwork")`**
   are banned by the same audit rule. Don't try to work around it.

6. **Run before pushing:**
   ```bash
   swift test --filter ManifoldInferenceTests --disable-default-traits
   ```

See [docs/THREAT_MODEL.md § B3 Build time ↔ run time](docs/THREAT_MODEL.md#b3-build-time--run-time).

## Adding a network feature

A new HTTP client, a new endpoint, a new request shape — anything that crosses the
network boundary.

1. **`URLSession` use is allowlisted per-file** by the audit's Rule 1
   (`networkIOAllowlist`). New network code goes in an existing allowlisted file
   when possible. Adding a *file* to the allowlist requires reviewer sign-off —
   the cap is intentionally low.

2. **Hostname literals** (`https?://[host]…`) are allowlisted by Rule 3. UI and
   Inference source must not contain hostname literals; cloud backend files do.

3. **All HTTP traffic must route through `URLSessionProvider`** so the runtime
   kill-switch (`URLSessionProvider.networkDisabled`) covers it.

4. **SSE responses** must consume through `SSEStreamParser` with the default
   `SSEStreamLimits` (or a justified narrower override). Don't bypass the bounds.

5. **Cloud error bodies** must run through `CloudErrorSanitizer.sanitize(_:host:)`
   before surfacing to the UI or `Log.*`.

6. **Run before pushing:**
   ```bash
   swift test --filter ManifoldBackendsTests --disable-default-traits
   swift test --filter ManifoldInferenceTests --disable-default-traits
   swift test --filter ManifoldTestSupportTests --disable-default-traits
   ```

See [SECURITY.md § Supported Build Modes](SECURITY.md#supported-build-modes) for
trait-mode behaviour and
[docs/THREAT_MODEL.md § Network exfiltration](docs/THREAT_MODEL.md#network-exfiltration).

## Adding a macro

Macros live in `Sources/ManifoldMacrosPlugin/`. They run at build time with full
shell privileges, so the rules are tighter:

1. **Banned in macro source:** `Foundation.URLSession`, `Process()`, `posix_spawn`.
   Audit Rule 2 catches these.

2. **Macro output** must be covered by a snapshot test so a future change to the
   macro doesn't silently rewrite generated source.

3. The macro plugin sandbox is on the Phase 5 roadmap
   ([#714](https://github.com/roryford/ManifoldKit/issues/714)). Until then, every
   macro change gets a manual security review.

4. **Run before pushing:**
   ```bash
   swift test --disable-default-traits   # exercises macro tests under all suites
   ```

See [docs/THREAT_MODEL.md § Build-time exfiltration via macros](docs/THREAT_MODEL.md#build-time-exfiltration-via-macros).

## Adding a setting / configuration flag

A new `ManifoldConfiguration` field, a new `@Environment` injection point, or a new
trait.

1. **Runtime configuration → `ManifoldConfiguration`.** Document the default in
   the field's doc comment.

2. **Build-time configuration → a new trait.** Add it to the `traits:` list in
   `Package.swift` with a one-line description. The audit's Rule 7 will
   immediately reject any `#if` typo against the new trait.

3. **If the flag affects a documented guarantee** (e.g. fail-closed behaviour,
   pinning policy, file-protection class), update
   [SECURITY.md § Supported Build Modes](SECURITY.md#supported-build-modes) and
   [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) in the same PR.

4. **README impact:** if the flag changes how a consumer chooses a build mode,
   update the README's build-mode decision table too.

5. **Run before pushing:**
   ```bash
   swift test --filter ManifoldCoreTests --disable-default-traits
   swift test --filter ManifoldInferenceTests --disable-default-traits
   ```

## Commit style

This project uses [Conventional Commits](https://www.conventionalcommits.org/).
Release Please reads commit messages to determine version bumps and to generate the
changelog.

```
feat: add streaming cancellation to FoundationBackend
fix: prevent context overflow when system prompt exceeds budget
perf: cache tokenizer lookups in ContextWindowManager
test: add XCTMeasure baselines for trimMessages hot path
chore: update mlx-swift-lm to 2.31.0
docs: clarify TokenizerProvider fallback behaviour
dx: surface decode errors in the model picker instead of silently failing
```

| Type                                  | Version bump      |
|---------------------------------------|-------------------|
| `feat`                                | MINOR (`0.x.0`)   |
| `fix`                                 | PATCH (`0.0.x`)   |
| `BREAKING CHANGE:` in footer          | MAJOR (`x.0.0`)   |
| `chore`, `docs`, `dx`, `test`, `perf` | no release        |

`dx:` is for changes that improve the developer experience of *consuming* ManifoldKit — clearer error messages, better onboarding docs in code, improved log output, simpler default APIs — without shipping new product features (`feat:`) or fixing user-facing bugs (`fix:`). It renders under a dedicated **Developer Experience** section in the changelog so DX work stays visible.

**PR titles are the enforced surface.** All PRs squash-merge, and Release Please reads the squashed PR title rather than the individual commit messages on the branch, so CI lints the *PR title* via [`amannn/action-semantic-pull-request`](https://github.com/amannn/action-semantic-pull-request). Individual commit messages on a feature branch should follow the same convention as a matter of habit, but they are not linted and can be reworded freely during review.

Add a body when the *why* needs explanation. Don't restate what the diff already
shows.

```
fix: prevent context overflow when system prompt exceeds budget

The trimMessages fallback returned an empty array when the system prompt
alone exceeded maxTokens. Always return at least the last user message so
generation has something to work with.
```

## DX budget

The project allocates one `dx:`-prefixed PR per minor release cycle exclusively
for developer-experience debt. This is calendar-driven, not opportunistic — DX
work loses to feature work every time when it competes for the same slot, so it
gets its own slot.

What counts:

- Pruning README accretion (target: ≤700 lines; current line count tracked per
  audit).
- Updating `docs/QUICKSTART.md` or `docs/FeatureMatrix.md` for clarity.
- Fixing error messages users see but don't understand.
- Smoothing rough edges in `Example/Examples/MinimalExample` or
  `Example/Advanced/`.
- Reviewing whether new traits or backends need matrix entries (the CI gate
  enforces *presence*; humans judge accuracy).

What doesn't count:

- Adding new features and labeling them `dx:` to dodge release-note budget —
  those are `feat:`.
- Bug fixes — those are `fix:`.

The DX budget issue is filed from the
[README pruning ritual issue template](.github/ISSUE_TEMPLATE/readme-prune.md)
at the start of each cycle. Maintainers can pick it up directly or label it
`good first issue` for community contributors.

## Pull request process

1. **Branch off `main`.** Direct pushes to `main` are blocked.
2. **Open a PR via `gh`:** `gh pr create --title "feat: ..." --body "..."`.
3. **Don't pass `--auto` or `--merge`.** Merges require human approval.
4. **Report the PR URL** so the maintainer can review.
5. **Wait for CI** before flagging "ready to merge". CI runs every CI-safe test
   suite listed in the [Pre-push checklist](#pre-push-checklist).

The maintainer merges PRs once at least one approval is received and CI is green.

## PR hygiene

CI is macOS-only and runs ~5 minutes per push. Each unnecessary PR or issue costs
real money and reviewer attention.

- **One feature = one PR**, even when it touches multiple backends. A change like
  "tool calling" or "thinking budget" should land as one PR with a backend
  checklist in the body, not five PRs.
- **Tests and docs ship in the feature PR.** Don't open standalone `test:` or
  `docs:` PRs for in-flight work — they cost CI minutes and invent merge
  conflicts. Standalone `test:` / `docs:` PRs are appropriate only for already-
  shipped features.
- **Single-file PRs are a smell.** Check whether there's a sibling PR you could
  batch into.
- **Don't open follow-up issues for "while I'm here" cleanups.** Fold them into
  the current PR or leave a `// TODO:` in the code. The issue tracker is for
  things that need cross-session memory **and** external visibility.

For the full PR-hygiene rationale, see [CLAUDE.md § Issue & PR hygiene](CLAUDE.md).

## Reporting bugs

Open a GitHub issue using the **Bug Report** template. Include:

- A minimal reproduction case.
- Platform and OS version (e.g. macOS 15.4, Apple M3).
- Swift and Xcode versions (`swift --version`, `xcodebuild -version`).
- Relevant log output.

Don't open public issues for security-impacting bugs — see the next section.

## Reporting security vulnerabilities

Use [GitHub Security Advisories](https://github.com/roryford/ManifoldKit/security/advisories/new)
for private disclosure. Full policy in [SECURITY.md](SECURITY.md#reporting-a-vulnerability).

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE) that covers this project.
