# Security Policy

BaseChatKit (BCK) is a Swift package for building local-first and cloud-optional chat
interfaces on Apple platforms. This document describes:

- [Supported versions](#supported-versions) — what gets security fixes.
- [Supported build modes](#supported-build-modes) — what each build mode guarantees,
  what enforces the guarantee, and what is explicitly **not** guaranteed.
- [Reporting a vulnerability](#reporting-a-vulnerability) — how to disclose privately.
- [Cryptography at rest](#cryptography-at-rest) — what the framework does with secrets and
  user data on disk.
- [Pending mitigations](#pending-mitigations) — known gaps with linked tracking issues.

For the full threat model (assets, trust boundaries, mitigations, and known
non-mitigations), see [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md). It also
covers the in-source mitigations (transport pinning, SSRF gating, error sanitisation,
SSE bounds, download path validation) at API granularity.

## Supported Versions

BCK is pre-1.0. Only the most recent minor release receives security fixes. Earlier
minors are end-of-life on the day a new minor ships.

| Version       | Status                          |
|---------------|---------------------------------|
| `0.12.x`      | Supported (security + bug fix)  |
| `0.11.x`      | Supported until `0.13.0`        |
| `< 0.11`      | End-of-life                     |

When BCK reaches `1.0.0`, this table will switch to a longer support window.

## Supported Build Modes

BCK ships four pre-blessed build modes, gated by Swift package traits. Each row of
the table below names exactly what is guaranteed for that mode and what enforces the
guarantee. Consumers in regulated verticals can compile the package in `offline` or
`ollama` mode and have a mechanically-checked guarantee that no SaaS-cloud code is
linked into the binary.

| Mode      | Default? | Traits enabled                | Backends linked                 |
|-----------|----------|-------------------------------|---------------------------------|
| `offline` | **Yes**  | `MLX`, `Llama`                | MLX, llama.cpp, Foundation      |
| `ollama`  | No       | `MLX`, `Llama`, `Ollama`      | + Ollama HTTP client            |
| `saas`    | No       | `MLX`, `Llama`, `CloudSaaS`   | + Claude, OpenAI                |
| `full`    | No       | all of the above              | every backend BCK ships         |

The default trait set today is `MLX, Llama` (per `Package.swift`), which corresponds
to the `offline` build profile. `Ollama` and `CloudSaaS` are both opt-in.

### Consumer manifest snippets

#### `offline` — local-only, no networking

```swift
.package(
    url: "https://github.com/roryford/BaseChatKit.git",
    from: "0.12.0",
    traits: [
        .trait(name: "MLX"),
        .trait(name: "Llama"),
    ]
)
```

**Guarantees** (enforced by [`TrafficBoundaryAuditTest`](Tests/BaseChatInferenceTests/TrafficBoundaryAuditTest.swift)
and the import-graph rule in the same audit):

- No `Sources/BaseChatBackends/Cloud/*` symbols are reachable.
- No `OllamaBackend`, `ClaudeBackend`, or `OpenAIBackend` is registered.
- No hostname literal pointing to `api.openai.com`, `api.anthropic.com`,
  or any third-party SaaS endpoint is reachable from app code.

**Not guaranteed:**

- A compromised toolchain or `Package.resolved` swap could swap source files; the audit
  only inspects what's checked in.
- `MLX` and `Llama` may still resolve **DNS** at startup if a host app calls
  HuggingFace search; the BCK API only resolves DNS via `URLSessionProvider`, which is
  not invoked from offline backends.
- A jailbroken device, rooted simulator, or hostile consumer-app code can bypass the
  framework's process-internal checks.

#### `ollama` — self-hosted / private datacenter

```swift
.package(
    url: "https://github.com/roryford/BaseChatKit.git",
    from: "0.12.0",
    traits: [
        .trait(name: "MLX"),
        .trait(name: "Llama"),
        .trait(name: "Ollama"),
    ]
)
```

Same `offline` guarantees, plus:

- HTTP traffic is permitted only via `URLSessionProvider`, which honours the runtime
  kill-switch `URLSessionProvider.networkDisabled`.
- `OllamaBackend` is the only HTTP-speaking backend present in the binary; no SaaS
  cloud code is linked.

**Not guaranteed:**

- BCK does not pin Ollama server certificates by default. If your deployment requires
  pinning, set `PinnedSessionDelegate.pinnedHosts["your.ollama.host"] = [...]` at
  startup.
- BCK does not validate the *content* the Ollama server returns — prompt-injection
  via tool output, retrieved documents, or model-card metadata is the host app's
  responsibility.

#### `saas` — full cloud

```swift
.package(
    url: "https://github.com/roryford/BaseChatKit.git",
    from: "0.12.0",
    traits: [
        .trait(name: "MLX"),
        .trait(name: "Llama"),
        .trait(name: "CloudSaaS"),
    ]
)
```

`saas` adds Claude and OpenAI backends. Pinning is **on by default** for both
hosts — the framework fails closed if no pin matches. See
[docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) for the SPKI pin set and the full
transport-security boundary.

#### `full` — every backend

```swift
.package(
    url: "https://github.com/roryford/BaseChatKit.git",
    from: "0.12.0",
    traits: [
        .trait(name: "MLX"),
        .trait(name: "Llama"),
        .trait(name: "Ollama"),
        .trait(name: "CloudSaaS"),
    ]
)
```

`full` is the maximum-surface developer build. Use it for development; pick a
narrower mode for shipping production binaries.

### What enforces each guarantee

| Mechanism                                                                                                                | Enforces                                                                                                            |
|--------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|
| [`TrafficBoundaryAuditTest`](Tests/BaseChatInferenceTests/TrafficBoundaryAuditTest.swift)                                | Rule classes 1–7: `URLSession` import allowlist, C interop / dynamic dispatch ban, hostname literals allowlist, privacy-API allowlist, `Package.swift` hygiene, import-graph layering, trait-name validity. |
| [`DenyAllURLProtocolTests`](Tests/BaseChatTestSupportTests/DenyAllURLProtocolTests.swift) and [`URLSessionProviderNetworkDisabledTests`](Tests/BaseChatBackendsTests/URLSessionProviderNetworkDisabledTests.swift) | Runtime network isolation: when `networkDisabled` is set, every URL request fails closed.                          |
| `#if Ollama` / `#if CloudSaaS` conditional compilation in `Sources/BaseChatBackends/`                                    | Trait-gated backend code is not compiled into the binary if the trait is absent.                                    |
| `--disable-default-traits` swift test invocations in CI (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml))      | At least one CI job exercises the offline trait set on every PR; signature regressions surface as compile errors.   |

There is currently no separate `scripts/build-modes.sh` — that consolidation is tracked
under the umbrella ([#714](https://github.com/roryford/BaseChatKit/issues/714)) and will
be added when the build-mode CI matrix lands.

### Explicit non-guarantees

The following are **not** in scope for any build mode. Treat them as host-app
responsibility:

- **Compromised toolchain** — a malicious Swift compiler or build plugin can re-add
  network code regardless of BCK's source-level audit.
- **Rooted / jailbroken device** — code injected into the host process can do anything.
- **Malicious consumer-app code** — BCK protects its own boundaries, not the host
  app's.
- **Side-channel timing attacks** — token-by-token streaming inherently leaks
  generation pace.
- **OS-level memory-mapped logs** — `os_log` redaction is a contract with the
  Console UI, not a hardware boundary; sysdiagnose or `log collect --private` recover
  redacted strings if invoked with elevated entitlements.
- **GGUF / safetensors weight tampering** — model-file integrity is the user's
  responsibility (typically via HuggingFace's signed manifest, which BCK does not
  yet verify; see [#367](https://github.com/roryford/BaseChatKit/issues/367)).

## Reporting a Vulnerability

Report suspected vulnerabilities through
[GitHub Security Advisories](https://github.com/roryford/BaseChatKit/security/advisories/new).
This keeps the discussion private until a fix is ready. Please **do not** open public
issues for security-impacting bugs.

Include:

- A description of the vulnerability and impact.
- Steps to reproduce.
- Affected versions (the `0.12.x` baseline plus any earlier minor you've reproduced
  on).
- Any potential mitigations or workarounds you've identified.

### Response timeline

| Step                            | Target           |
|---------------------------------|------------------|
| Acknowledge report              | 48 hours         |
| Triage and severity assessment  | 5 business days  |
| Patch release                   | 30 days          |

Complex issues may extend the timeline. We will keep you informed of progress and
credit reporters in the release notes for confirmed vulnerabilities unless you ask
for anonymity.

### Disclosure policy

We follow coordinated disclosure: once a fix is released, a security advisory with
full details is published. We ask reporters to wait until the advisory is published
before disclosing publicly.

There is no bug bounty programme today.

## Cryptography at Rest

| Asset                              | Mechanism                                                                                                                                |
|------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| API keys                           | System Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, **not** synced via iCloud Keychain. Per-endpoint UUID accounts.         |
| SwiftData store (chat history)     | `NSFileProtection.completeUntilFirstUserAuthentication` (default) on iOS / iPadOS / tvOS / watchOS. Opt in to `.complete` via `BaseChatConfiguration.fileProtectionClass`. |
| Model weights                      | Plain files under `modelsDirectory`. Path-traversal validation runs at filename ingest (`DownloadableModel.validate(fileName:)`). No content-integrity check today. |
| In-flight TLS                      | SPKI-pinned for `api.openai.com` and `api.anthropic.com`; pluggable via `PinnedSessionDelegate.pinnedHosts` for custom hosts.            |

BCK is **not** FIPS-validated. The Apple Keychain and Apple's `Security.framework` use
CoreCrypto, which has FIPS-140-3 validations on supported OS versions, but BCK does
not pin to or verify those validations at runtime.

For deployments that need stricter at-rest sealing, set
`BaseChatConfiguration.shared.fileProtectionClass = .complete` and ship background
work that is robust to a locked device.

## Pending Mitigations

The following are known gaps with tracking issues. Each is listed in
[docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) under "Known non-mitigations":

- **Macro plugin sandbox** — SwiftPM `.buildToolPlugin` / `.commandPlugin` declarations
  are banned by the audit, but `Sources/BaseChatMacrosPlugin/` runs at build time with
  full filesystem and network access. Tracked under
  [#714](https://github.com/roryford/BaseChatKit/issues/714) Phase 5.
- **xcframework checksum pinning** — `llama.swift` and `mlx-swift` xcframeworks are
  pulled by SwiftPM with `Package.resolved` revision pinning but no SHA-256 binary
  checksum. Tracked under [#714](https://github.com/roryford/BaseChatKit/issues/714)
  Phase 5.
- **GGUF signed-manifest verification** — model weights downloaded from HuggingFace
  are not signature-verified.
  [#367](https://github.com/roryford/BaseChatKit/issues/367).
- **Build-provenance attestation** — no SLSA-style attestation. Tracked under
  [#714](https://github.com/roryford/BaseChatKit/issues/714) Phase 5.
- **Secure Enclave / key zeroization** — API keys are read into Swift `String` for
  request signing and rely on ARC + zeroing-on-free behaviour from
  Foundation/Security.framework. Tracked under
  [#714](https://github.com/roryford/BaseChatKit/issues/714) Phase 5.
- **SBOM** — no Software Bill of Materials is published. Tracked under
  [#714](https://github.com/roryford/BaseChatKit/issues/714) Phase 5.
- **FIPS validation** — see Cryptography at Rest above. No commitment to a FIPS-only
  build path.

For the complete breakdown — including how each gap maps onto a procurement-team
checklist — see [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).

## Cross-references

- [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) — full threat model, including the
  in-source mitigations (transport pinning, SSRF gating, Keychain, error sanitisation,
  SSE bounds, download path validation) at API granularity.
- [CONTRIBUTING.md](CONTRIBUTING.md) — contributor guide indexed by change type.
  Each change-type section lists the security-relevant gates.
- [README.md](README.md) — quick-start, build-mode decision table, and feature
  overview.
