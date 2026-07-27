# Migration: instance-scoped security policy (#2293)

**Audience:** consumer (anyone setting `ManifoldConfiguration.shared`'s security
fields, or subclassing/constructing the network delegates directly)
**Status:** living

**Applies to:** hosts that set `networkPolicy`, `customHostTrustPolicy`, or
`allowUnpinnedCredentialedHosts`; anyone constructing `PinnedSessionDelegate`,
`CompositeURLSessionDelegate`, or calling
`ConnectAddressPinningDelegate.pinnedData(for:on:)`.

## Why

`ManifoldConfiguration.shared` is process-global. It is data-race-free (it sits
behind an `OSAllocatedUnfairLock`), which is precisely why it slid past every
existing audit — it is not `nonisolated(unsafe)`, not a raw `UserDefaults`. But
it is still **last-write-wins**, and three of its fields are
security-load-bearing:

| Field | What it gates |
|-------|---------------|
| `customHostTrustPolicy` | whether an unpinned custom host falls back to OS trust or fails closed |
| `allowUnpinnedCredentialedHosts` | whether `Authorization` may be sent to a non-loopback host with no SPKI pins |
| `networkPolicy` | the outbound host allowlist, on initial requests and redirect targets |

Two `ManifoldBootstrap` instances in one process — a multi-window Mac app, a
multi-account app, SwiftUI Previews sharing a process with live code — contend
for that global. Window B setting
`ManifoldConfiguration.shared = ManifoldConfiguration(allowUnpinnedCredentialedHosts: true, customHostTrustPolicy: .platformDefault)`
for its own dev endpoint **silently downgraded TLS pinning for window A's
production traffic**, with no log line naming who did it.

## What changed

### 1. A value type: `ManifoldSecurityPolicy`

The three fields are now also expressible as a value a service graph owns:

```swift
import ManifoldKit

let policy = ManifoldSecurityPolicy(
    networkPolicy: .allowlist(["api.mycompany.com"]),
    customHostTrustPolicy: .requireExplicitPins,
    allowUnpinnedCredentialedHosts: false
)
```

`ManifoldConfiguration.securityPolicy` reads and writes the same three fields,
so `configuration.securityPolicy` is the bridge from an existing configuration.

### 2. `InferenceService.securityPolicy` is the owning instance

**Instance scoping is opt-in, and the default is unchanged.** `ManifoldBootstrap`
does *not* derive the policy from the configuration you hand it — you pass it
explicitly:

`ManifoldBootstrap.init(configuration:…securityPolicy:)`,
`ManifoldBootstrap.build(configuration:…securityPolicy:)` and
`makeInMemory(configuration:inferenceService:ragConfiguration:securityPolicy:)`
all take `securityPolicy: ManifoldSecurityPolicy? = nil`. Leave it off and this
graph keeps resolving `ManifoldConfiguration.shared` live at use time — exactly
the pre-#2293 behaviour.

> **Why not derive it automatically?** Because the enforcement seams resolve
> `securityPolicy?.X ?? ManifoldConfiguration.shared.X`. A non-`nil` policy makes
> the `?? global` branch dead, so a host that sets a configuration at startup and
> later *tightens* `ManifoldConfiguration.shared.customHostTrustPolicy` would
> silently stop getting that tightening — unpinned custom hosts falling back to OS
> trust where they previously failed closed. Auto-seeding would have turned this
> change into a fail-open for every single-graph host. Opting in has to be a
> decision, not a side effect of using the bootstrap.

`ManifoldKit.quickStart(...)` deliberately does **not** expose the parameter — it
is the single-session convenience path. A multi-graph process should use
`ManifoldBootstrap.build(configuration:securityPolicy:)` directly.

Once you opt in, the backend registrars (`CloudSaaSBackends.register(with:)`,
`OllamaBackends.register(with:)`) read the policy at registration time and build
policy-scoped sessions and backends from it. If you build an `InferenceService`
yourself, set the policy *before* registering, because the registrars snapshot it:

```swift
import ManifoldKit

@MainActor
func makeService(configuration: ManifoldConfiguration) -> InferenceService {
    let service = InferenceService()
    service.securityPolicy = configuration.securityPolicy   // ← before register
    CloudSaaSBackends.register(with: service)
    OllamaBackends.register(with: service)
    return service
}
```

### 3. The enforcement seams take a policy

Each of these gained an optional `securityPolicy` parameter. **`nil` is the
default everywhere and means "resolve `ManifoldConfiguration.shared` at use
time" — byte-for-byte the old behaviour, including mutations made after the
object was constructed.** No call site is forced to change.

Passing a non-`nil` policy is what trades live tracking away: from then on that
object is pinned to the value you gave it and later global mutations do not reach
it. That is the point for a multi-graph process, and the reason `nil` is the
default everywhere.

```swift,no-build:signature catalogue; each line names a seam rather than forming a compilable program, and several types are package-internal
PinnedSessionDelegate(securityPolicy: policy)                      // customHostTrustPolicy
CompositeURLSessionDelegate(redirectGuard: guard,
                            securityPolicy: policy)                // networkPolicy on redirects
URLSessionFactory.ephemeral(securityPolicy: policy)
URLSessionFactory.background(identifier: id, securityPolicy: policy)
URLSessionProvider.pinned(securityPolicy: policy)                  // policy-scoped pinned session
URLSessionProvider.unpinned(securityPolicy: policy)
someSSECloudBackend.securityPolicy = policy                        // allowUnpinnedCredentialedHosts
```

`ConnectAddressPinningDelegate.pinnedData(for:on:)` is the exception: it takes no
policy parameter. It reads the policy **off the session** it was handed (from the
session's `CompositeURLSessionDelegate`), so its callers — `CloudReranker`,
`DefaultWebSearchRuntime`, `OllamaModelListService`, `OllamaModelProbe` — get
scoped enforcement automatically whenever they are given a policy-scoped session,
with no call-site change. For `CloudReranker` (which sends `Authorization` and is
therefore the one credentialed path here), that means:

```swift,no-build:fragment; `policy` and `cohereKey` come from the host's own setup
CloudReranker.cohere(
    apiKey: cohereKey,
    urlSession: URLSessionProvider.pinned(securityPolicy: policy)
)
```

Hand it the default (or no) session and it resolves the transitional global, as
before.

`PinnedSessionDelegate()` previously used the implicit `NSObject` initialiser; it
now has an explicit `init(securityPolicy:)` with a `nil` default, so
`PinnedSessionDelegate()` still compiles and still reads the global.

### 4. `NetworkPolicyURLProtocol` is a most-restrictive backstop, not a global read

`canInit(with:)` is an `override class func` Foundation drives with only a
`URLRequest`; `URLSessionTask` exposes no back-reference to its session, so this
one path genuinely cannot be instance-scoped. Instead of last-write-wins it now
resolves the **intersection** of every live registered policy and the
transitional global (`NetworkPolicyRegistry`). The fold only ever tightens, so
one graph relaxing its own policy can never relax another's.

Two consequences worth knowing:

- **Disjoint allowlists fail closed, process-wide.** If graph A allows only
  `a.com` and graph B only `b.com`, the effective allowlist for this backstop is
  empty. Be clear about the blast radius: this is **not** scoped to the two graphs
  that disagree. `NetworkPolicyURLProtocol` is installed on every
  `URLSessionConfiguration` `URLSessionFactory` builds, so an empty effective
  allowlist blocks initial requests on *every* session in the process —
  HuggingFace model downloads, LAN probes, and sessions belonging to graphs that
  never opted in. This is deliberate and it is the fail-closed direction: the old
  behaviour for the same configuration was that the last writer won and everyone
  else *silently lost their restriction*. A warning is logged at registration when
  a registrant's own allowlist is narrowed by the fold, which is the signal that
  this has happened. Note the intersection is suffix-aware —
  `{"example.com"} ∩ {"sub.example.com"}` is `{"sub.example.com"}`, not the empty
  set, because an entry admits its subdomains.
- **Registry entries are owned by the service graph, and released when it dies.**
  The entry hangs off `InferenceService`, so a torn-down bootstrap stops
  restricting the graphs that outlive it with nothing required of you. In
  particular: **do not invalidate the sessions `URLSessionProvider.pinned(securityPolicy:)`
  / `unpinned(securityPolicy:)` return.** They are cached by policy for the process
  lifetime, exactly like `URLSessionProvider.pinned`, and invalidating one would
  hand the next graph with an equal policy a dead session. (An earlier draft of
  this note said the opposite; that advice was wrong.)

### 5. Security-field mutations are logged

Assigning `ManifoldConfiguration.shared` now emits one `Log.security` warning per
changed security field, naming the field and both values:

```
ManifoldConfiguration.shared security field mutated — customHostTrustPolicy: platformDefault -> requireExplicitPins; allowUnpinnedCredentialedHosts: false -> true
```

Non-security fields (`appName`, `features`, keychain naming) are not audited —
they are not security-relevant and would only add noise.

## What you should do

**If you set the security fields once at startup and run one bootstrap:**
nothing. Do not opt in. The global still works, is still read live wherever you
have not passed an explicit policy, and later mutations still take effect.

**If you run more than one bootstrap / service graph in a process:** opt in per
graph — `ManifoldBootstrap.build(configuration: c, securityPolicy: c.securityPolicy)`
— and if you construct sessions or delegates yourself, pass the policy explicitly.
Accept that each opted-in graph is then pinned to the policy you gave it: change
it by assigning `inferenceService.securityPolicy`, not by writing the global.

**If you were working around the global** — save/restore `defer` dances around
`ManifoldConfiguration.shared` in tests, ordering constraints on who configures
first — pass an explicit `ManifoldSecurityPolicy` instead.

## What did *not* change

- The **other ~75** `ManifoldConfiguration.shared` reads (`appName`,
  `bundleIdentifier`, `features`, `sseStreamLimits`, keychain naming) still go
  through the global. They are not security-load-bearing.
- `PinnedSessionDelegate.pinnedHosts` is still process-global static state. Pin
  sets are shared across every graph in the process; scoping them is separate
  work.
- Default values are unchanged: `.unrestricted`, `.platformDefault`, `false`.
- The default bootstrap and `quickStart` paths behave exactly as before, down to
  live tracking of later global mutations. Nothing is instance-scoped unless you
  ask for it.
