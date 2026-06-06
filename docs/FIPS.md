# FIPS 140-3 Posture

> **Audience:** procurement, compliance, and security teams evaluating ManifoldKit
> for use in regulated environments (healthcare, federal-adjacent, finance,
> defense). This document answers the question
> "are your cryptographic primitives FIPS 140-3 validated?"
>
> **TL;DR:** ManifoldKit does not hold a FIPS 140-3 validation certificate, and does not
> claim to. ManifoldKit calls into Apple's platform crypto APIs (CryptoKit, CommonCrypto,
> Security.framework). Whether those calls land inside a FIPS-validated boundary
> depends entirely on the deployment OS version and Apple's published validation
> certificates for that OS — the validation boundary is the operating system, not
> ManifoldKit. A regulated downstream app must validate this independently against its
> deployment-target OS and procurement requirements.

## Why this document exists

When ManifoldKit is evaluated for use in a healthcare, federal, or defense-adjacent
context, the procurement question that surfaces is some variant of:

> "Are your cryptographic primitives FIPS 140-3 validated?"

The accurate answer for an Apple-platform Swift package is nuanced enough that a
naive "yes" or "no" would mislead. Producing this written, sourced answer up
front prevents weeks of round-tripping with security teams asking the same
question across multiple integrations.

This document does **not** claim ManifoldKit is FIPS-validated. It documents *which*
cryptographic primitives ManifoldKit invokes, *where* the validation boundary actually
sits (in the OS, not in ManifoldKit), and *what a downstream regulated app must verify
independently* before claiming a FIPS posture for its own deployment.

## Scope and boundary

| Layer | Owner | FIPS status |
|---|---|---|
| Application code (ManifoldKit + your app) | You + ManifoldKit | **Outside** the validated boundary. Calls platform APIs. |
| `CryptoKit`, `CommonCrypto`, `Security.framework` | Apple | API surface only; routes calls into the validated module below. |
| `Apple CoreCrypto` kernel/user-space module | Apple | The actual FIPS 140-3 validated module — **only on specific OS versions, with specific configurations.** |
| Hardware (Secure Enclave, AES engine) | Apple | Separate validations exist; not used directly by ManifoldKit today. |

The only layer that holds a FIPS 140-3 certificate is Apple CoreCrypto, and only
on the OS versions Apple has submitted for validation. ManifoldKit's code is part of the
"application code" row — it is **outside** any validation boundary.

## Inventory of cryptographic primitives used by ManifoldKit

This is a complete inventory as of v0.12.2. It is generated from a manual audit
of every `import CryptoKit`, `import CommonCrypto`, and `import Security` site
in the source tree.

### 1. Certificate pinning (`PinnedSessionDelegate`)

- **File:** `Sources/ManifoldBackends/PinnedSessionDelegate.swift`
- **Primitive:** `CC_SHA256` (CommonCrypto) over the server leaf certificate's
  SPKI (Subject Public Key Info).
- **Purpose:** TLS pinning. Each new connection's leaf-cert SPKI is hashed and
  compared against the configured pin set for that host.
- **Companion call:** `SecKeyCopyExternalRepresentation` (Security.framework) to
  extract the public key bytes to hash.
- **Validation boundary:** `CC_SHA256` is part of `libcommonCrypto.dylib`, which
  routes into CoreCrypto on validated OS versions. The hash itself is a
  one-way digest used for equality comparison; there is no key material in ManifoldKit's
  process that is governed by this primitive.

### 2. Keychain (`KeychainService`)

- **File:** `Sources/ManifoldInference/Services/KeychainService.swift`
- **Primitive:** `SecItemAdd`, `SecItemUpdate`, `SecItemCopyMatching`,
  `SecItemDelete` (Security.framework) with class
  `kSecClassGenericPassword` and accessibility
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- **Purpose:** Storing API keys for cloud backends (OpenAI, Anthropic, etc.).
- **Validation boundary:** Keychain item storage and the at-rest encryption of
  the keychain database are managed entirely by the OS. ManifoldKit never sees the
  cipher, IV, or wrapping key. This is the strongest part of ManifoldKit's posture —
  the application code is a thin wrapper over a platform-managed store.

### 3. UUID v5 generation (`UUID+v5`)

- **File:** `Sources/ManifoldInference/Utilities/UUID+v5.swift`
- **Primitive:** `Insecure.SHA1` (CryptoKit).
- **Purpose:** Deterministic name-based UUIDs per RFC 4122 §4.3 (used to derive
  stable identifiers from string names — for fixtures, deduplication, etc.).
- **Validation boundary:** SHA-1 is *not* a FIPS-approved hash for security
  use. It is used here for **non-security identifier derivation** only. The
  CryptoKit `Insecure.` namespace is the deliberate flag: this primitive is not
  part of any security boundary in ManifoldKit.

### 4. MCP OAuth PKCE + token-prefix logging (`MCPOAuth`)

- **File:** `Sources/ManifoldMCP/MCPOAuth.swift`
- **Primitives:**
  - `SHA256.hash` (CryptoKit) over the PKCE code verifier — required by RFC 7636.
  - `SecRandomCopyBytes` (Security.framework) for PKCE verifier and state nonce.
  - `SHA256.hash` of bearer tokens, truncated to a 4-byte prefix for log
    correlation. The full token is never logged.
- **Validation boundary:** SHA-256 and `SecRandomCopyBytes` route into
  CoreCrypto on validated OS versions. The PKCE flow itself follows
  RFC 7636 — ManifoldKit does not implement custom crypto here.

### 5. Fuzz harness fingerprinting (`ManifoldFuzz`)

- **Files:**
  - `Sources/ManifoldFuzz/Finding.swift` (`SHA256.hash` for finding-key digests)
  - `Sources/ManifoldFuzz/HarnessMetadata.swift` (`SHA256` streaming digest of
    GGUF model files for run reproducibility)
- **Primitive:** `SHA256` (CryptoKit).
- **Purpose:** Deterministic fingerprints for fuzz-finding deduplication and
  model-file identity. **Not security-relevant** — no key material, no signing.
- **Validation boundary:** Same as above. The `ManifoldFuzz` module is not
  shipped to production apps; it is a developer-only test harness.

### 6. Future Secure Enclave usage

ManifoldKit does **not** currently use `SecKeyCreateRandomKey` with
`kSecAttrTokenIDSecureEnclave`, `LAContext`, or any Secure Enclave-backed key
material. If this is added in a future release, it will be documented here and
in the [Security Model DocC article][secmodel].

### What ManifoldKit does **not** use

ManifoldKit does **not** implement, vendor, or call out to:

- Custom AES, ChaCha20, HMAC, or signature primitives.
- Bouncy Castle, OpenSSL, libsodium, or any third-party crypto library.
- Any non-Apple TLS stack. All HTTPS goes through `URLSession` / Network.framework.
- JWT signing, JWS, JWE, or any in-process token-issuance crypto.

Tokens received from cloud APIs are stored in Keychain (see §2) and submitted as
`Authorization: Bearer` headers over `URLSession`. ManifoldKit does not sign requests,
mint tokens, or hold long-lived key material outside Keychain.

## Apple CoreCrypto FIPS 140-3 validation linkage

ManifoldKit targets **n−1**: the current Apple OS release plus the one immediately
before (see [CLAUDE.md](../CLAUDE.md) "Platform policy"). At the time of
writing, that floor is **macOS 15** and **iOS 18**.

For any given deployment target, you must look up Apple's published FIPS
certificate matching that OS version on NIST's
[Cryptographic Module Validation Program (CMVP) search][cmvp]. Apple submits
CoreCrypto for each major OS release; the cert numbers, status (Active /
Historical), and applicable security policy document are published per version.

> **This document does not enumerate cert numbers**, because:
>
> 1. NIST CMVP entries change status (Active → Historical) on a 5-year rolling
>    schedule independent of Apple's release calendar. A cert listed here today
>    may be Historical by the time you read it.
> 2. The exact module name on the certificate ("Apple corecrypto Module
>    [User, Hardware, Kernel] vN.N.N") changes between OS versions and
>    sub-modules, and procurement requirements typically pin a specific module
>    flavor (user-space vs. kernel vs. SEP-resident).
>
> The correct procedure is: **for your deployment OS version, search the CMVP
> directly**, retrieve the current certificate, and read its security policy
> document to confirm the validated configuration matches how your app will run.

### What "configuration matches" means in practice

Apple's CoreCrypto validation typically requires:

- The OS to be in its **as-shipped** configuration (no jailbreak, no boot-args
  tampering, no custom kernel extensions on the validated boundary).
- Specific algorithm/keysize selections — e.g., AES-256-GCM may be in-boundary
  while a legacy mode is not. CryptoKit and Security.framework on a validated OS
  default to in-boundary algorithms, but a downstream app calling
  `Insecure.MD5` or `Insecure.SHA1` is explicitly outside.
- For some certs, FIPS mode is **not enabled by default** and must be activated
  via a configuration profile (MDM) or a process entitlement. Read the security
  policy for the cert.

A regulated downstream app is responsible for confirming each of these matches
its deployment.

## Gap list — things ManifoldKit does outside the validated boundary

This list is what an enterprise security reviewer should know before signing
off. It is exhaustive as of v0.12.2.

1. **`CC_SHA256` invoked directly from Swift.** `PinnedSessionDelegate` calls
   `CC_SHA256` via the CommonCrypto C API rather than `CryptoKit.SHA256`. The
   underlying implementation is the same on all validated OS versions
   (CommonCrypto routes to CoreCrypto), but the call site is in ManifoldKit's process,
   so the bytes-in / bytes-out boundary crosses ManifoldKit. There is no key material
   here; the hash is used only for fingerprint comparison.
2. **`Insecure.SHA1` use in UUID v5.** SHA-1 is non-approved. It is used for
   identifier derivation, not security. A reviewer who flags this should be
   pointed at the comment in `UUID+v5.swift` and RFC 4122 §4.3, which
   explicitly specifies SHA-1.
3. **API keys are held in `String` for the duration of an HTTP request.**
   `KeychainService` reads keys just-in-time, but during the body of a
   `URLSession` task the bytes exist in process memory as a regular `String`.
   They are not zeroized after use. Memory zeroization for transient secrets
   is **not implemented** — see #714 Phase 5 non-mitigations.
4. **No build-attestation or reproducible-build provenance** is published for
   ManifoldKit releases. A regulated deployment that requires SLSA-style provenance
   on the ManifoldKit package will need to build from source under its own attested
   pipeline (the source is on GitHub at a tagged commit; `Package.resolved`
   pins all transitive dependencies).
5. **Binary xcframeworks** (`llama.swift`, `mlx-swift`) are pre-built and
   shipped via Swift Package Manager. They contain no ManifoldKit-supplied
   cryptography, but they do contain Metal compute shaders and inference code.
   See [Binary Dependencies](../README.md#binary-dependencies) in the README.
6. **Secure Enclave** is not currently used (see §6 above). API keys live in
   the standard Keychain, not the SEP. A deployment that requires SEP-bound
   credentials is outside ManifoldKit's current capability.
7. **KV-cache residue** from local inference (MLX, llama.cpp) is held in
   process memory and may be paged to disk by the OS. There is no in-memory
   wipe at conversation end. Sensitive prompts in a high-assurance environment
   should be paired with platform-level memory protection (e.g., disabling
   swap on macOS via MDM, or using `mlock` — neither implemented in ManifoldKit).

## Recommendations for FIPS-required deployments

If your deployment requires "FIPS 140-3 validated cryptography is in use"
language in its ATO (Authority to Operate) or vendor questionnaire response:

1. **Pin your deployment-target OS version** to one with a current Active CMVP
   certificate for Apple corecrypto. Confirm the certificate via the [CMVP
   search][cmvp] at the time of submission, and re-confirm on each OS upgrade.
2. **Read the security policy** for the cert. Confirm the validated
   configuration matches your app's runtime — particularly whether FIPS mode
   needs to be activated via a configuration profile.
3. **Distribute via MDM** with a configuration profile that locks the OS
   version, disables jailbreak, and (if required by the cert) enables FIPS
   mode.
4. **Disable cloud backends** if your deployment is local-only. Use the
   `Ollama` and `CloudSaaS` traits to compile out SaaS code paths entirely
   (see #714 Phases 1–4). This shrinks the audit surface for "data leaves
   the device" review.
5. **Consider Keychain access groups + the Data Protection class
   `NSFileProtectionComplete`** for any persisted data adjacent to ManifoldKit
   (SwiftData stores, exports). ManifoldKit uses
   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for its own keychain items,
   which is the strongest non-interactive class.
6. **Plan for cert lifecycle.** CMVP certs move to Historical status on a
   5-year rolling schedule. A long-lived deployment will need to re-validate
   against a newer cert when the original moves to Historical. This is an OS
   upgrade question, not a ManifoldKit question — but ManifoldKit's `n−1` policy means at
   least one supported OS version always has a current cert at any given
   time.

## What ManifoldKit will and will not do

| Request | Answer |
|---|---|
| Add a FIPS-validated crypto primitive to ManifoldKit directly. | **No.** Validating a separate module is a multi-year, six-figure undertaking and the right answer is to use the validated OS module. |
| Document which ManifoldKit call sites cross the OS boundary. | **Yes** — see the inventory above. We will keep this current per release. |
| Publish the CMVP cert numbers for currently supported OSes. | **No** — cert lifecycle is independent of ManifoldKit's release cycle. Look them up at submission time. |
| Add `mlock` / memory-zeroization for in-process secrets. | **Tracked** under #714 Phase 5 non-mitigations. Not implemented today. |
| Add Secure Enclave-backed credential storage. | **Not currently planned.** File a feature request if you need this. |
| Provide a SLSA build-provenance attestation. | **Tracked** under #714 Phase 5. Not implemented today. |

## Out of scope

- Obtaining a separate FIPS 140-3 certificate for ManifoldKit code. This is a
  multi-year, six-figure undertaking that is only justified for federal-mandate
  deployments where no validated platform module exists. On Apple platforms,
  the validated platform module (CoreCrypto) is the right tool.
- Validating cryptography in transitive Swift package dependencies. We pin
  versions in `Package.resolved` and review crypto-adjacent dependencies
  manually, but no transitive dependency holds a FIPS cert independently.
- Running ManifoldKit on non-Apple platforms (Linux for CI is compile-only). Any
  Linux execution path falls back to `swift-crypto`, which is **not**
  FIPS-validated.

## Reviewer checklist

Use this when responding to a procurement security review:

- [ ] Deployment-target OS version is pinned and matches a current Active
      CMVP certificate for Apple corecrypto.
- [ ] If FIPS mode is required by the cert, an MDM configuration profile
      activates it on managed devices.
- [ ] Cloud backends are either disabled (via `Ollama`/`CloudSaaS` traits) or
      explicitly approved for the data classification in scope.
- [ ] The application code's own crypto usage (your code, not ManifoldKit's) has
      been audited against the same boundary criteria as §3 above.
- [ ] The gap list (§"Gap list") has been reviewed and any
      gaps that affect your deployment have a documented mitigation or
      acceptance.
- [ ] Cert-lifecycle ownership: the team that owns the deployment knows when
      the relied-upon CMVP cert is scheduled to move to Historical.

## References

- NIST CMVP search: <https://csrc.nist.gov/projects/cryptographic-module-validation-program/validated-modules/search>
- FIPS 140-3 standard: NIST FIPS PUB 140-3.
- Apple Platform Security Guide:
  <https://support.apple.com/guide/security/welcome/web>
- RFC 7636 (PKCE): <https://datatracker.ietf.org/doc/html/rfc7636>
- RFC 4122 §4.3 (UUID v5): <https://datatracker.ietf.org/doc/html/rfc4122#section-4.3>
- ManifoldKit Security Model DocC article: see [`SecurityModel.md`][secmodel]
- ManifoldKit Security Policy: [`.github/SECURITY.md`](../.github/SECURITY.md)
- ManifoldKit Threat Model (when published): `THREAT_MODEL.md` — tracked under #736.

---

*This document is part of Phase 5 of [#714](https://github.com/roryford/ManifoldKit/issues/714)
("local-only build modes + privacy validation infra"). It is reviewed on each
release that touches `Sources/**/*.swift` files importing `CryptoKit`,
`CommonCrypto`, or `Security`.*

[cmvp]: https://csrc.nist.gov/projects/cryptographic-module-validation-program/validated-modules/search
[secmodel]: ../Sources/ManifoldCore/ManifoldCore.docc/Articles/SecurityModel.md
