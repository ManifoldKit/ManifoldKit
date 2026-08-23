# Security Policy

ManifoldKit is a Swift package for building local-first and cloud-optional chat
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

ManifoldKit is pre-1.0. Only the most recent minor release receives security fixes. Earlier
minors are end-of-life on the day a new minor ships.

| Version       | Status                          |
|---------------|---------------------------------|
| `0.72.x`      | Supported (security + bug fix)  |
| `< 0.72`      | End-of-life (earlier minors)    |

When ManifoldKit reaches `1.0.0`, this table will switch to a longer support window.

## Supported Build Modes

ManifoldKit documents four **product-graph** build modes (not SwiftPM trait
modes — traits for cloud/local backends retired in v0.48). Each row of the
table below names exactly what is guaranteed for that mode and what enforces
the guarantee. Consumers in regulated verticals can build the `offline` or
`ollama` product graph and have a mechanically-checked guarantee that no
SaaS-cloud code is linked into the binary.

Since v0.48 the build-mode traits are retired (the `Ollama`/`CloudSaaS` traits
in PR A4; the `MLX`/`Llama`/`HuggingFace`/`Fuzz`/`FoundationOnly` traits with
the companion-package split in PR C2): cloud sources always compile in the
package, and the heavy local backends live in the `manifold-mlx` /
`manifold-llama` companion packages. Excluding cloud code from a shipped binary
is a **link-out** decision — build/link only the products you need — not a
compile flag; excluding the local ML stacks is even stronger — core never
resolves them. The build modes map to product graphs (see
`scripts/build-modes.sh`):

| Mode      | Build invocation                                        | Cloud code linked              |
|-----------|---------------------------------------------------------|--------------------------------|
| `offline` | `--target ManifoldUI`                                   | none                           |
| `ollama`  | `--target ManifoldOllama`                               | Ollama HTTP client + shared TLS-pinning infra (`ManifoldCloudCore`) |
| `saas`    | `--target ManifoldCloudSaaS`                            | Claude, OpenAI + shared infra  |
| `full`    | plain `swift build`                                     | every backend ManifoldKit ships |

### Consumer manifest snippets

#### `offline` — local-only, no networking

```swift
.package(
    url: "https://github.com/ManifoldKit/ManifoldKit.git",
    from: "0.76.1" // x-release-please-version
)
// For local inference add the companion package(s) and registrars:
// .package(url: "https://github.com/ManifoldKit/manifold-llama.git", from: "0.1.0")
// .package(url: "https://github.com/ManifoldKit/manifold-mlx.git", from: "0.1.0")
```

**Guarantees** (enforced by [`TrafficBoundaryAuditTest`](Tests/ManifoldInferenceTests/TrafficBoundaryAuditTest.swift)
and the import-graph rule in the same audit):

- No cloud backend symbols (`Sources/ManifoldCloudSaaS/*`, `Sources/ManifoldCloudCore/*`) are reachable.
- No `OllamaBackend`, `ClaudeBackend`, or `OpenAIBackend` is registered.
- No hostname literal pointing to `api.openai.com`, `api.anthropic.com`,
  or any third-party SaaS endpoint is reachable from app code.

**Not guaranteed:**

- A compromised toolchain or `Package.resolved` swap could swap source files; the audit
  only inspects what's checked in.
- The companion MLX / Llama backends may still resolve **DNS** at startup if a host app calls
  HuggingFace search; the ManifoldKit API only resolves DNS via `URLSessionProvider`, which is
  not invoked from offline backends.
- A jailbroken device, rooted simulator, or hostile consumer-app code can bypass the
  framework's process-internal checks.

#### `ollama` — self-hosted / private datacenter

```swift
.package(
    url: "https://github.com/ManifoldKit/ManifoldKit.git",
    from: "0.76.1" // x-release-please-version
)
// Cloud backends always compile since v0.48; depend on the ManifoldOllama
// product (and not ManifoldCloudSaaS) for the ollama-mode link surface.
```

Same `offline` guarantees, plus:

- HTTP traffic is permitted only via `URLSessionProvider`, which honours the runtime
  kill-switch `URLSessionProvider.networkDisabled`.
- `OllamaBackend` is the only HTTP-speaking backend present in the binary; no SaaS
  cloud code is linked.

**Not guaranteed:**

- ManifoldKit does not pin Ollama server certificates by default. If your deployment requires
  pinning, set `PinnedSessionDelegate.pinnedHosts["your.ollama.host"] = [...]` at
  startup.
- ManifoldKit does not validate the *content* the Ollama server returns — prompt-injection
  via tool output, retrieved documents, or model-card metadata is the host app's
  responsibility.

#### `saas` — full cloud

```swift
.package(
    url: "https://github.com/ManifoldKit/ManifoldKit.git",
    from: "0.76.1" // x-release-please-version
)
// Cloud backends always compile since v0.48; depend on the ManifoldCloudSaaS
// product for the SaaS link surface.
```

`saas` adds Claude and OpenAI backends. Pinning is **on by default** for both
hosts — the framework fails closed if no pin matches. See
[docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) for the SPKI pin set and the full
transport-security boundary.

#### `full` — every backend

```swift
.package(
    url: "https://github.com/ManifoldKit/ManifoldKit.git",
    from: "0.76.1" // x-release-please-version
)
// All cloud backends are compiled in. Add the manifold-mlx / manifold-llama
// companion packages for the maximum-surface build.
```

`full` is the maximum-surface developer build. Use it for development; pick a
narrower mode for shipping production binaries.

### What enforces each guarantee

| Mechanism                                                                                                                | Enforces                                                                                                            |
|--------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|
| [`TrafficBoundaryAuditTest`](Tests/ManifoldInferenceTests/TrafficBoundaryAuditTest.swift)                                | Rule classes 1–7: `URLSession` import allowlist, C interop / dynamic dispatch ban, hostname literals allowlist, privacy-API allowlist, `Package.swift` hygiene, import-graph layering, trait-name validity. |
| [`DenyAllURLProtocolTests`](Tests/ManifoldTestSupportTests/DenyAllURLProtocolTests.swift) and [`URLSessionProviderNetworkDisabledTests`](Tests/ManifoldBackendsTests/URLSessionProviderNetworkDisabledTests.swift) | Runtime network isolation: when `networkDisabled` is set, every URL request fails closed.                          |
| Per-mode symbol audit in `scripts/build-modes.sh` (nightly, `.github/workflows/build-modes.yml`)                          | Cloud backend code is not *linked* into a product graph that excludes it (link-out claim; the compile-out traits were retired in v0.48). |
| Plain `swift test` CI invocations (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)) | Every CI job exercises the full core surface (there are no default traits since v0.48); signature regressions surface as compile errors. |

### Explicit non-guarantees

The following are **not** in scope for any build mode. Treat them as host-app
responsibility:

- **Compromised toolchain** — a malicious Swift compiler or build plugin can re-add
  network code regardless of ManifoldKit's source-level audit.
- **Rooted / jailbroken device** — code injected into the host process can do anything.
- **Malicious consumer-app code** — ManifoldKit protects its own boundaries, not the host
  app's.
- **Side-channel timing attacks** — token-by-token streaming inherently leaks
  generation pace.
- **OS-level memory-mapped logs** — `os_log` redaction is a contract with the
  Console UI, not a hardware boundary; sysdiagnose or `log collect --private` recover
  redacted strings if invoked with elevated entitlements.
- **GGUF / safetensors weight tampering** — model-file integrity is the user's
  responsibility (typically via HuggingFace's signed manifest, which ManifoldKit does not
  yet verify; see [#367](https://github.com/ManifoldKit/ManifoldKit/issues/367)).

## Reporting a Vulnerability

Report suspected vulnerabilities through
[GitHub Security Advisories](https://github.com/ManifoldKit/ManifoldKit/security/advisories/new).
This keeps the discussion private until a fix is ready. Please **do not** open public
issues for security-impacting bugs.

Include:

- A description of the vulnerability and impact.
- Steps to reproduce.
- Affected versions (the `0.72.x` baseline plus any earlier minor you've reproduced
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
| SwiftData store (chat history)     | `NSFileProtection.completeUntilFirstUserAuthentication` (default) on iOS / iPadOS / tvOS / watchOS. Opt in to `.complete` via `ManifoldConfiguration.fileProtectionClass`. |
| Model weights                      | Plain files under `modelsDirectory`. Path-traversal validation runs at filename ingest (`DownloadableModel.validate(fileName:)`). No content-integrity check today. |
| In-flight TLS                      | SPKI-pinned for `api.openai.com` and `api.anthropic.com`; pluggable via `PinnedSessionDelegate.pinnedHosts` for custom hosts. Credentialed requests to unpinned non-loopback hosts fail closed by default (`allowUnpinnedCredentialedHosts = false`). |

ManifoldKit is **not** FIPS-validated. The Apple Keychain and Apple's `Security.framework` use
CoreCrypto, which has FIPS-140-3 validations on supported OS versions, but ManifoldKit does
not pin to or verify those validations at runtime.

For deployments that need stricter at-rest sealing, set
`ManifoldConfiguration.shared.fileProtectionClass = .complete` and ship background
work that is robust to a locked device.

## MCP Threat Model

ManifoldKit's MCP client (`MCPClient`) connects to external tool servers. Each server is
a trust boundary: a compromised or malicious server can attempt prompt injection, data
exfiltration, and SSRF. This section documents the mitigations and the residual risks
that host apps must address.

### STDIO opt-in requirement

STDIO transport spawns a local subprocess with the app's process privileges. Unlike
HTTP, there is no TLS, no SSRF guard, and no revocation path — the transport is as
trusted as the executable on disk. `MCPServerDescriptor.allowsSTDIOTransport` defaults
to `false`; connecting to a `stdio` endpoint without setting it throws:

```
MCPError.transportFailure("STDIO transport requires explicit opt-in via
MCPServerDescriptor.allowsSTDIOTransport. See SECURITY.md for the threat model.")
```

Before setting `allowsSTDIOTransport = true`, verify:

- The executable is code-signed with a known requirement (set `codesignRequirement`
  on `MCPStdioCommand` to enforce this at runtime on macOS).
- The executable path cannot be replaced by a less-privileged user or an adversarial
  package install script.
- The working directory and environment passed to the subprocess do not contain
  secret credentials.

### Auth requirement

`MCPServerDescriptor.isUnauthenticatedUnsafe` defaults to `false`. Connecting to a
server with `authorization: .none` without setting this flag throws:

```
MCPError.transportFailure("MCP server has no auth configuration. Set
isUnauthenticatedUnsafe: true to permit unauthenticated connections.")
```

Unauthenticated servers have no cryptographic identity. Tool call arguments and return
values are sent in the clear. This is acceptable for loopback-only servers (e.g., a
locally-launched STDIO process that is also the only user of the port), but is a
significant risk for any network-reachable endpoint.

### Metadata sanitization

`MCPContentSanitizer` wraps all tool output in an untrusted-content envelope and strips
ANSI/DEC terminal escape sequences, control characters, and envelope-escape injection
attempts before the content reaches the model's context window.

`MCPToolSource` caps tool names and descriptions by UTF-8 byte count. When content
contains known prompt-injection indicator phrases (`"ignore previous"`, `"system:"`,
`"override"`, `"disregard"`, `"[STOP]"`), a warning is written to `Log.inference` instead
of silently dropping the content — stripping silently would hide the attack from
operators. The scan covers the tool name, the top-level tool description, **and all
`description` fields nested inside the JSON Schema** (parameter descriptions). Parameter
descriptions flow verbatim into the model's context window and are an equally viable
injection vector. Host apps should forward `os_log` output from the
`com.manifoldkit.inference` subsystem to their observability pipeline.

Note: the detection list uses the bracketed form `[STOP]` rather than the bare word
`stop` to avoid false-positive warnings for common tool descriptions that mention
stopping a process. Operators should treat any logged indicator as a signal requiring
review, not automatic proof of an attack.

### Process isolation guidance

ManifoldKit does not sandbox MCP server processes. Process isolation is the host app's
responsibility:

- On macOS, launch STDIO server processes inside an `NSXPCConnection` with a restricted
  sandbox profile or use App Sandbox entitlements on the server binary.
- On iOS/iPadOS, STDIO is unavailable. Use `streamableHTTP` against a loopback server
  launched via a macOS companion app or an on-device HTTP server library.
- Restrict the server process's file-system access to the minimum needed. Do not pass
  the app's home directory as the working directory.
- Do not forward `HOME`, `PATH`, or other ambient credentials from the parent
  environment unless the server explicitly requires them.

## Pending Mitigations

The following are known gaps with tracking issues. Each is listed in
[docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) under "Known non-mitigations":

- **Macro plugin sandbox** — SwiftPM `.buildToolPlugin` / `.commandPlugin` declarations
  are banned by the audit, but `Sources/ManifoldMacrosPlugin/` runs at build time with
  full filesystem and network access. Tracked under
  [#714](https://github.com/ManifoldKit/ManifoldKit/issues/714) Phase 5.
- **xcframework checksum pinning** — `llama.swift` and `mlx-swift` xcframeworks are
  pulled by SwiftPM with `Package.resolved` revision pinning but no SHA-256 binary
  checksum. Tracked under [#714](https://github.com/ManifoldKit/ManifoldKit/issues/714)
  Phase 5.
- **GGUF signed-manifest verification** — model weights downloaded from HuggingFace
  are not signature-verified.
  [#367](https://github.com/ManifoldKit/ManifoldKit/issues/367).
- **Build-provenance attestation** — no SLSA-style attestation. Tracked under
  [#714](https://github.com/ManifoldKit/ManifoldKit/issues/714) Phase 5.
- **Secure Enclave / key zeroization** — API keys are read into Swift `String` for
  request signing and rely on ARC + zeroing-on-free behaviour from
  Foundation/Security.framework. Tracked under
  [#714](https://github.com/ManifoldKit/ManifoldKit/issues/714) Phase 5.
- **SBOM** — no Software Bill of Materials is published. Tracked under
  [#714](https://github.com/ManifoldKit/ManifoldKit/issues/714) Phase 5.
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
