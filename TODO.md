# TODO

Cross-session notes. Not a tracker — real work lives in GitHub issues.

## Next up

- **Start Glass Box P0 after v0.38 ships.** Umbrella: [#1531](https://github.com/roryford/ManifoldKit/issues/1531).
  P0 = productionize the multicast event tap + public `ConversationEventRecorder`
  (`ManifoldRuntime`) + Swift-6 tests + "Observing a turn" DocC article.
  Keystone already spiked on branch `spike/conversation-event-tap` (c8d654fc) —
  reproduce properly, that branch is throwaway validation, not for merge.
  When P0 lands, update the `feedback_mock_backend_and_events_test_patterns` note
  (the single-consumer `runtime.events` workaround is what the tap retires).

## Positioning / distribution follow-ups (2026-06-06)

Came out of the competitive-positioning pass (see [docs/POSITIONING.md](docs/POSITIONING.md)
+ [docs/LAUNCH-BRIEF.md](docs/LAUNCH-BRIEF.md)). Tracked issues: RAG rerank
[#1637](https://github.com/roryford/ManifoldKit/issues/1637), AnyLanguageModel bridge
[#1638](https://github.com/roryford/ManifoldKit/issues/1638). The rest are DX/polish kept
off the tracker per issue-hygiene policy — fold into a PR opportunistically:

- **Structured-output ergonomic surface.** The machinery is complete and capability-routed
  (`StructuredOutputStrategy` / `StructuredOutputTarget` / `StructuredOutputRouter`), but a
  consumer must assemble a `StructuredOutputTarget` and know the routing. A one-liner
  convenience (`generate(MyType.self)`) or `@Generable`-style macro on top would match the
  Apple/Vercel ergonomics — pure sugar over the existing surface, not new capability.
  (`Sources/ManifoldInference/Models/StructuredOutputStrategy.swift`)
- **`streamIdleTimeout` defaults to unset.** Idle-timeout stall detection exists but is
  opt-in; cloud backends never synthesize `streamInterrupted` on a silent EOF. Consider a
  conservative default so the common case gets stall detection for free. Documented as a
  deliberate decision in `docs/RELIABILITY.md`.
- **Pre-launch discoverability (repo settings, not a PR):** set GitHub topics, add a README
  badge row, ship a 1280×640 social preview, set `homepageUrl`. See LAUNCH-BRIEF §1 P0.

## Footgun audit follow-ups (2026-06-05)

Tracked issues: security [#1621](https://github.com/roryford/ManifoldKit/issues/1621),
correctness bugs [#1622](https://github.com/roryford/ManifoldKit/issues/1622),
structural enforcement [#1623](https://github.com/roryford/ManifoldKit/issues/1623).

Deferred consumer-extension hazards (kept out of the tracker per issue-hygiene policy —
fold into a PR opportunistically, no standalone issues):

- **`GenerationEvent` is a non-frozen public enum (18 cases).** Every minor that adds a
  case source-breaks consumers' exhaustive switches; `default:` silently swallows new
  lifecycle events. Consider a source-stable consumption façade for BYO-UI consumers.
  (`Sources/ManifoldInference/Models/GenerationEvent.swift:40`)
- **`RetryStrategy` has no absolute attempt backstop.** The retry loop only terminates when
  the strategy returns `nil`; a naive constant-delay conformer wedges. The shipped
  `ExponentialBackoffStrategy` is safe — the gap is the open protocol.
  (`Sources/ManifoldInference/Services/RetryPolicy.swift:122`)
- **`maxThinkingTokens = 0` is a silent no-op on backends that haven't wired the 0-case.**
  Already marked deferred in the type doc; name implies a CoT-suppression guarantee it
  doesn't deliver. (`Sources/ManifoldInference/Protocols/InferenceBackend.swift:204`)
- **`ManifoldConfiguration.shared.<field> = …` is a lossy read-modify-write.** Each get/set
  is atomic but per-field mutation is get-struct→mutate→set-struct; concurrent writers to
  different fields lose an update. Documented as "set once at startup."
  (`Sources/ManifoldInference/ManifoldConfiguration.swift:24`)
- **DNS-rebind TOCTOU** — already tracked/deferred in `MCPSSRFPolicy.swift:169` (full IP
  pinning to the connection). Noted here for completeness; no new action.
