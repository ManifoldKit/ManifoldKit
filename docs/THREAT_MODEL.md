# ManifoldKit Threat Model

This document is the engineering companion to [SECURITY.md](../SECURITY.md). Where
SECURITY.md is the customer-facing summary ("what ManifoldKit guarantees, who it's for, what to
do with a vulnerability"), this document is the line-by-line procurement checklist:
what is enforced, what is **not** enforced, and which CI mechanism or open issue maps
to each row.

The format is deliberate: every "X is enforced by Y" claim links to the actual file or
workflow. Every "X is not mitigated" row names the tracking issue (or explains why an
item is permanently out of scope).

For a higher-level narrative — and the corresponding DocC API surface — see the
[Security Model](../Sources/ManifoldCore/ManifoldCore.docc/Articles/SecurityModel.md)
article.

## Audience and scope

ManifoldKit targets **integrators building Apple-platform chat applications**. The threat
model covers everything ManifoldKit ships in source form: the Swift modules, the test infra,
the trait gates, and the documented configuration surface. It does **not** cover host
application code, third-party model weights, or operating-system primitives ManifoldKit
relies on (Keychain, file protection, `URLSession`, MLX, llama.cpp).

Build modes — `offline`, `ollama`, `saas`, `full` — are summarised in
[SECURITY.md](../SECURITY.md#supported-build-modes). This document references them
where the threat surface differs by mode.

## Assets

What ManifoldKit is trying to protect, in priority order:

1. **API keys.** Stored in Keychain with
   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Compromise of an API key gives an
   attacker billable access to a third-party SaaS account; the key may also have
   organisation-scoped read access to provider chat history.
2. **Message history.** Stored as SwiftData rows on disk. Chat content frequently
   contains personally-identifiable information, work-confidential prompts, source
   code, and pasted credentials.
3. **Model files.** Multi-gigabyte GGUF / safetensors files on disk. Theft of a
   downloaded model weight is rarely high-impact (the same weights are usually
   public on HuggingFace), but tampering — replacing a weight with a backdoored
   one — can cause the chat UI to render attacker-chosen output.
4. **Conversation KV-cache residue.** The llama.cpp and MLX backends retain
   per-session KV state for the lifetime of the load. A second user inheriting the
   same `LlamaBackend` instance can in principle observe earlier conversation
   tokens via timing or memory inspection. (Single-user devices, ManifoldKit's primary
   target, mostly defang this.)
5. **Build-time secrets.** Developer dotfiles, `Package.resolved` URLs, and macro
   plugin source. A macro plugin runs at build time with the dev shell's full
   privileges; an attacker who lands a malicious macro can read `~/.ssh`, the
   user's keychain, environment variables, and so on.

## Trust boundaries

ManifoldKit distinguishes the following boundaries. Each subsection summarises what is
considered hostile on the far side and what ManifoldKit validates as data crosses.

### B1. Network ↔ device

- **Hostile side:** the network. Includes not only the public internet but any
  device-local interface that resolves to a non-loopback IP (LAN, VPN, AirPlay,
  printer subnet, AWS metadata service `169.254.169.254`).
- **What crosses:** outbound HTTP requests to cloud LLM providers and Ollama; SSE
  responses; HuggingFace search/download metadata.
- **Mitigations enforced today:**
  - SPKI-pinned TLS for `api.openai.com`, `api.anthropic.com` (default pin set
    populates from `PinnedSessionDelegate.loadDefaultPins()`; both hosts fail
    closed).
  - SSRF gate in `APIEndpoint.validate()` rejects RFC1918 / link-local / metadata
    IPs and unsupported URL schemes before persistence.
  - All outbound requests route through `URLSessionProvider`, which honours the
    runtime kill-switch `URLSessionProvider.networkDisabled`.
  - SSE streams bounded by `SSEStreamLimits` (event ≤ 1 MB, total ≤ 50 MB,
    rate ≤ 5,000 events/sec).
  - Error bodies sanitised by `CloudErrorSanitizer.sanitize(_:host:)` before
    surfacing to the UI or `Log.*`.
- **Not mitigated:** DNS rebinding (validation runs at endpoint persist time, not
  request time); user-installed MITM root CAs (corporate proxies, jailbreak
  tweaks); compromised pinning trust store.

### B2. Disk ↔ process

- **Hostile side:** another app or another local user with disk access. On iOS this
  requires Data Protection bypass (jailbreak); on macOS, another user account or a
  locally-installed signed app the user trusts.
- **What crosses:** SwiftData store reads/writes; Keychain reads/writes; model
  file reads.
- **Mitigations enforced today:**
  - SwiftData store sealed with
    `NSFileProtection.completeUntilFirstUserAuthentication` (default; opt-in
    `.complete`).
  - Keychain items use the no-iCloud-sync access class.
  - `ManifoldBootstrap.reapOrphanedKeychainItems(in:)` sweeps orphaned Keychain
    entries on startup.
  - Filename validation (`DownloadableModel.validate(fileName:)`) rejects path
    traversal at ingest; `modelsDirectory` placement enforces a
    `.standardized.path` prefix check.
  - 24-hour stale-temp sweep in `BackgroundDownloadManager.cleanupStaleTempFiles()`.
- **Not mitigated:** macOS at-rest encryption is FileVault (out-of-process); ManifoldKit
  does no extra sealing on macOS. MLX Metal KV-cache buffers are evicted (not
  zeroed) on session switch — explicit zeroing is not available via the current
  MLX API. `LlamaBackend` zero-wipes KV tensors via `llama_memory_clear(mem, true)`.

### B3. Build time ↔ run time

- **Hostile side:** an attacker who has landed a commit, a Package.resolved swap,
  or a malicious upstream dependency.
- **What crosses:** SwiftPM dependency resolution; macro plugin execution; binary
  xcframework downloads.
- **Mitigations enforced today:**
  - `Package.swift` hygiene rules (Rule 5 of `TrafficBoundaryAuditTest`):
    `linkedFramework("Network")`, `linkedFramework("CFNetwork")`, `unsafeFlags`,
    and `.buildToolPlugin` / `.commandPlugin` declarations are banned in
    `Package.swift` and caught at PR time.
  - Trait-gate sanity (Rule 7): every `#if` token in `Sources/` must match a
    declared trait, so a typo cannot silently include backend code.
  - C interop ban (Rule 2): `@_silgen_name`, `@_cdecl`, `dlopen`, `dlsym`,
    `NSClassFromString`, `Process(`, `posix_spawn`, etc. are banned across
    `Sources/` (with one narrow `Process(` allowlist for the Fuzz CLI).
- **Not mitigated:** xcframework checksum pinning (binary deps pulled by revision,
  not SHA-256); macro plugin sandbox (`Sources/ManifoldMacrosPlugin/` has full
  filesystem + network access at build time); SLSA-style build provenance; SBOM.
  All tracked under [#714](https://github.com/roryford/ManifoldKit/issues/714)
  Phase 5.

### B4. User content ↔ model

- **Hostile side:** the user (in a multi-tenant deployment) or any input source the
  model treats as text — pasted documents, retrieved tool output, web snippets.
- **What crosses:** user prompts, tool-call results, retrieved RAG content,
  pasted clipboard contents.
- **Mitigations enforced today:**
  - `PromptTemplate` strips structural special tokens (`<|im_start|>`, `[INST]`,
    `<|eot_id|>`, etc.) from user content per template family.
- **Not mitigated:** semantic prompt injection. **ManifoldKit does not solve
  prompt injection.** System prompts are not a security boundary; tool calls and
  retrieved content are untrusted from the model's perspective. See the
  [Security Model](../Sources/ManifoldCore/ManifoldCore.docc/Articles/SecurityModel.md#prompt-injection-explicit-disclaimer)
  article for guidance.

### B5. UI / framework ↔ host application

- **Hostile side:** consumer-app code that links ManifoldKit. ManifoldKit protects its own
  invariants (Keychain access patterns, kill-switch honour, audit allowlists), not
  the host app's.
- **What crosses:** dependency-injection points (`InferenceService`,
  `ChatViewModel.inferenceService`, `ManifoldConfiguration.shared`); SwiftData
  schemas; closure injection points (`apiConfiguration` view-builder on
  `ChatView`).
- **Mitigations enforced today:** import-graph audit (Rule 6) ensures ManifoldKit's own
  modules cannot regress (UI cannot import Backends; Inference cannot import Core
  or Backends); `package`-visibility on `ChatViewModel.inferenceService`
  prevents leaking the full `InferenceService` API on the public boundary.
- **Not mitigated:** consumer apps that subclass, swizzle, or otherwise bypass
  ManifoldKit's APIs. ManifoldKit is a library, not a sandbox.

## Threats considered

For each named threat: what it is, what mitigates it (with link), and gaps.

### Network exfiltration

- **Threat:** A SaaS-cloud backend, a misconfigured HTTP client, or a future code
  change quietly exfiltrates conversation content to an unintended host.
- **Mitigations:** All HTTP traffic must route through `URLSessionProvider`
  ([`Sources/ManifoldCloudCore/URLSessionProvider.swift`](../Sources/ManifoldCloudCore/URLSessionProvider.swift)).
  The audit's hostname-literal rule (Rule 3) keeps endpoint URLs out of UI/Inference
  source files. The runtime `DenyAllURLProtocol`
  ([`Sources/ManifoldTestSupport/DenyAllURLProtocol.swift`](../Sources/ManifoldTestSupport/DenyAllURLProtocol.swift))
  is registered on default + ephemeral configurations in tests, exercising every
  backend in the offline build mode.
- **Gaps:** None outstanding for in-tree code. Out-of-tree consumer code is the
  host app's responsibility.

### Disk theft (lost / stolen device)

- **Threat:** Unattended device with the SwiftData store readable.
- **Mitigations:** `NSFileProtection.completeUntilFirstUserAuthentication`
  (default) seals the store after device reboot until first unlock. Opt in to
  `.complete` for stricter behaviour at the cost of background-task availability.
- **Gaps:** macOS uses FileVault for at-rest sealing; ManifoldKit does no extra work
  there. iCloud Keychain sync is disabled at the API level (Keychain access
  class), so a recovered iCloud backup does not include API keys.

### Process memory inspection

- **Threat:** A debugger, a corrupt log dump, or a memory-mapped log harvests
  prompts, keys, or KV-cache state from the running process.
- **Mitigations:** API keys read just-in-time (no stored properties); on the
  Keychain read path, secrets are wrapped in ``SecureBytes`` (a `memset_s`-backed
  zeroing buffer) rather than a plain Swift `String`.
  `Log.*` calls use `privacy: .private` for credentials/prompts and `.public`
  only for stable identifiers (host, file name, OSStatus).  On session end or
  `clearChat()`, `LlamaBackend.secureWipe()` zero-wipes KV tensor data; the
  `SecureEnclaveKeyManager` provides hardware-backed P-256 key wrapping on
  capable devices.
- **Gaps:** `os_log` `.private` is enforced by Console redaction, not memory
  protection. Sysdiagnose with elevated entitlements recovers redacted strings.
  MLX Metal buffers cannot be explicitly zeroed via the current MLX Swift API —
  `Memory.clearCache()` evicts pooled allocations but does not write zeros.

### Supply chain

- **Threat:** A compromised dependency adds network code, runs malicious code at
  build time, or replaces a model weight.
- **Mitigations:** `Package.swift` hygiene audit (Rule 5) blocks
  `linkedFramework("Network")`, `unsafeFlags`, and SwiftPM plugin declarations.
  Trait-gate sanity (Rule 7) catches typos before they let unintended code
  through.
- **Gaps:** xcframework checksum pinning, macro plugin sandbox, build-provenance
  attestation, SBOM. All tracked under
  [#714](https://github.com/roryford/ManifoldKit/issues/714) Phase 5. Model
  weight signature verification:
  [#367](https://github.com/roryford/ManifoldKit/issues/367).

### Unintended local network leaks

- **Threat:** mDNS/Bonjour announces a chat session to the local network; a
  CloudKit container accidentally syncs message rows; Handoff broadcasts the
  current chat to nearby devices.
- **Mitigations:** Audit Rule 4 bans `CloudKitDatabase`, `NSUbiquitous*`,
  `NSUserActivity` Handoff, `UIPasteboard.general` writes without `localOnly`,
  and `FileProtectionType.none` from `Sources/`. Each finding requires an
  explicit fingerprint entry with justification.
- **Gaps:** The audit is a source grep — a host app can still call any of these
  APIs. ManifoldKit does not whitelist them at runtime.

### Build-time exfiltration via macros

- **Threat:** A macro plugin under `Sources/ManifoldMacrosPlugin/` reads developer
  secrets at build time and exfiltrates them.
- **Mitigations:** Audit Rule 2 bans `Foundation.URLSession`, `Process()`,
  `posix_spawn` from macro source until a sandbox is in place.
- **Gaps:** The audit is a static check; a sufficiently motivated attacker can
  obfuscate. Macro plugin sandbox is on the Phase 5 roadmap
  ([#714](https://github.com/roryford/ManifoldKit/issues/714)).

### `os_log` content escape via sysdiagnose

- **Threat:** `Log.*` calls with `privacy: .public` accidentally include user
  content; `log collect --private` on macOS recovers `.private` content with
  developer entitlement.
- **Mitigations:** Convention is `.private` for any user content, prompts, or
  credentials; `.public` only for stable identifiers.
- **Gaps:** Convention is enforced by code review, not by the audit. Adding a
  static-grep rule for `%{public}` near a `String` interpolation of user content
  is an open item.

## Mitigations summary table

The procurement view: which mitigation, which mechanism, where it lives.

| Mitigation                                          | Enforced by                                                                                              | Run when?                       |
|-----------------------------------------------------|----------------------------------------------------------------------------------------------------------|---------------------------------|
| Network I/O imports allowlist                       | `TrafficBoundaryAuditTest` Rule 1                                                                        | Every PR (CI: `ManifoldInferenceTests`) |
| C interop / dynamic dispatch ban                    | `TrafficBoundaryAuditTest` Rule 2                                                                        | Every PR                         |
| Hostname literal allowlist                          | `TrafficBoundaryAuditTest` Rule 3                                                                        | Every PR                         |
| Privacy-sensitive Apple API allowlist               | `TrafficBoundaryAuditTest` Rule 4                                                                        | Every PR                         |
| `Package.swift` hygiene                             | `TrafficBoundaryAuditTest` Rule 5                                                                        | Every PR                         |
| Import-graph layering                               | `TrafficBoundaryAuditTest` Rule 6                                                                        | Every PR                         |
| Trait-gate sanity                                   | `TrafficBoundaryAuditTest` Rule 7                                                                        | Every PR                         |
| Runtime network kill-switch                         | `URLSessionProvider.networkDisabled` + `DenyAllURLProtocolTests`                                         | Every PR                         |
| Cloud TLS pinning fail-closed                       | `PinnedSessionDelegate` (defaults populated for `api.openai.com`, `api.anthropic.com`)                   | Every cloud HTTP request         |
| SSRF gate at endpoint persist                       | `APIEndpoint.validate()`                                                                                 | UI form submit + programmatic    |
| SSE stream bounds                                   | `SSEStreamParser` + `SSEStreamLimits.default`                                                            | Every SSE response               |
| Cloud error sanitisation                            | `CloudErrorSanitizer.sanitize(_:host:)`                                                                  | Every cloud error path           |
| Path-traversal validation at filename ingest        | `DownloadableModel.validate(fileName:)` + `modelsDirectory` `.standardized.path` prefix check            | Manifest parse + download start  |
| Stale temp sweep                                    | `BackgroundDownloadManager.cleanupStaleTempFiles()`                                                      | App launch                       |
| Keychain orphan reaper                              | `ManifoldBootstrap.reapOrphanedKeychainItems(in:)` (gated by `keychainReaperEnabled`)                    | App launch                       |
| At-rest sealing (iOS / iPadOS / tvOS / watchOS)     | `ModelContainerFactory.makeContainer(...)` applies `ManifoldConfiguration.fileProtectionClass`           | Container creation               |
| Prompt structural sanitisation                      | `PromptTemplate` (per-format special-token strip)                                                        | Every user message interpolation |

## Known non-mitigations

Each item is either deferred to a tracked issue or explicitly out of scope.

### Deferred (tracked under [#714](https://github.com/roryford/ManifoldKit/issues/714) Phase 5 unless noted)

- **Macro plugin sandbox.** `Sources/ManifoldMacrosPlugin/` runs at build time with
  full filesystem + network access. Audit Rule 2 currently bans network primitives
  by static grep; a sandbox is the long-term fix.
- **xcframework checksum pinning.** `llama.swift` and `mlx-swift` xcframeworks are
  pinned by SwiftPM revision. Binary checksum pinning would defend against a
  compromised release tarball.
- **Build-provenance attestation.** No SLSA-style attestation today.
- **Secure Enclave / FIPS / key zeroization.** *(Partially mitigated.)* The
  Keychain read path now wraps secrets in ``SecureBytes`` (`memset_s` zeroing on
  deallocation) rather than a plain Swift `String`.
  ``SecureEnclaveKeyManager`` provides a hardware-backed P-256 SE keypair for
  wrap/unwrap on capable devices (opt-in via `ManifoldConfiguration.useSecureEnclave`).
  ``LlamaBackend.secureWipe()`` calls `llama_memory_clear(mem, true)` to zero KV
  tensor data. **Remaining gap:** MLX Metal buffers cannot be explicitly zeroed via
  the current MLX Swift API; `Memory.clearCache()` evicts pooled allocations but
  does not guarantee zero-filling.
- **SBOM.** No published Software Bill of Materials.
- **GGUF signed-manifest verification.** Tracked separately at
  [#367](https://github.com/roryford/ManifoldKit/issues/367).
- **Reproducible builds.** Not validated.

### Explicitly out of scope

- **MDM / managed-app-config.** ManifoldKit does not parse managed-app-config plists; host
  apps that need MDM-driven configuration must wrap `ManifoldConfiguration`
  themselves.
- **Model-bundling recipes.** Shipping a model bundled inside the app binary is
  technically possible but not documented or supported.
- **DYLD_INTERPOSE socket shims.** A library cannot defend against a host-process
  `DYLD_INSERT_LIBRARIES` attack; this is an OS-trust problem.
- **Physical-access and social-engineering attacks.** Stolen device with PIN,
  phishing for an API key, etc.
- **Local denial-of-service** (e.g. loading a model that exhausts memory). The
  framework reports memory pressure (`ModelLoadPlan` + denial policies) but cannot
  prevent a host app from forcing a heavyweight load.
- **Vulnerabilities in upstream dependencies.** Report those directly to the
  upstream project (mlx-swift, llama.swift, swift-transformers, etc.).

## Cross-references

- [SECURITY.md](../SECURITY.md) — disclosure policy, supported versions, build-mode
  guarantees.
- [Security Model](../Sources/ManifoldCore/ManifoldCore.docc/Articles/SecurityModel.md)
  — DocC article covering in-source mitigations at API granularity.
- [`TrafficBoundaryAuditTest`](../Tests/ManifoldInferenceTests/TrafficBoundaryAuditTest.swift)
  — the source-grep audit referenced throughout.
- [`DenyAllURLProtocol`](../Sources/ManifoldTestSupport/DenyAllURLProtocol.swift)
  — the runtime network-isolation canary.
- [CONTRIBUTING.md](../CONTRIBUTING.md) — contributor change-type index. Every
  change-type section names the security gates that apply.
