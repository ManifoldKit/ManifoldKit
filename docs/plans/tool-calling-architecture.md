# Tool-calling architecture: from per-family whack-a-mole to a template-derived `ChatProfile`

> **Status (2026-06-24):** design proposal, not yet scheduled. Synthesises four code investigations across `ManifoldKit` + `manifold-llama` + `manifold-mlx` with comparative research into llama.cpp, Ollama, mlx-lm, vLLM, HuggingFace transformers, the constrained-decoding libraries (outlines / xgrammar / llguidance), and the multi-backend kits (llama-cpp-python, node-llama-cpp, LangChain, LiteLLM). The aim is to fix the *principle*, not just the open matrix findings — to give the tool-calling subsystem a pattern that holds as families multiply.

> **Companion-repo caveat.** The local raw-token backends (`ManifoldLlama`, `ManifoldMLX`) live in [`ManifoldKit/manifold-llama`](https://github.com/ManifoldKit/manifold-llama) and [`ManifoldKit/manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx). Several changes below land there, not in core. File:line references to those repos are marked **(companion)**.

> **Research-freshness caveat.** Most secondary sources still describe llama.cpp's *old* `common_chat_format`-enum + per-format-regex model. Current master (PR #17136, merged 2025-12-03) is a **PEG-as-single-source-of-truth** design. This doc designs against the new model. Verify before citing the old one.

> **Adversarial-review status (2026-06-24).** Stress-tested by four independent review workers (codebase-truth, external-research, YAGNI/over-engineering, migration-risk). **The diagnosis and comparative research survived intact** — all six current-code claims and all three external keystones (llama.cpp #17136, vLLM #27766/#22132, the Apple APIs + "no provider-extension" correction) verified against source. **The migration plan did not survive unchanged** and §3/§5/§6 below were rewritten in response. The three load-bearing corrections, each verified directly against the code:
> 1. **"Behaviour-preserving consolidation" was wrong** — the three taxonomies *contradict each other today* (Gemma close-delimiter: `ToolCallDialect.swift:14` `<tool_call|>` vs `ChatTemplateToolDescriptor.swift:157` `<|/tool_call>`). There is no single ground truth to preserve; Phase 1 is reframed as *behaviour-defining* (adjudicate contradictions against real templates), not preserving.
> 2. **Phase 2 was not "90% wired"** — `ToolGrammarBuilder` is *dialect-blind* (bare `{"name","arguments"}` envelope, eager prose escape, no native `[TOOL_CALLS]`/`<tool_call>` wrapper, no lazy gating). Dialect-aware grammar + trigger-gating are net-new.
> 3. **Phase 0 carries a real Llama regression risk** and the cost column was optimistic ~2–3×. Costs and sequencing rewritten; a re-measure precondition added.
>
> Note also: the matrix this doc cites was measured on *this stale branch* (predates #2032/#2035); its evidence base must be re-measured on `origin/main` before scheduling (see §5 precondition).

---

## 1. Diagnosis: the fragility is a principle problem, not a bug backlog

The cross-backend conformance matrix (`docs/plans/archive/runs/20260622-232839/MATRIX.md`) reads as a list of unrelated failures — Mistral render-fail on llama.cpp, Mistral no-call on MLX, gemma renders-no-call everywhere, qwen silent on llama.cpp. It is not. **Every failing cell is a backend where MK reimplements what the model's chat template already encodes; every clean cell is a backend where MK delegates.**

| | Render (prompt) | Parse (output) | Matrix result |
|---|---|---|---|
| **Delegated** — Ollama, OpenAI, Claude, openai-compat | Server applies the model's own template (`/api/chat` + structured `messages` + `tools`) | Server returns structured `tool_calls` | every ✅ except llama3.x |
| **In-Swift raw-token** — llama.cpp, MLX **(companion)** | MK renders in-process (`JinjaPromptRenderer`, or the 7-family `PromptTemplate` enum fallback) | MK reverse-parses the token stream (`ToolCallTransform` + per-family `ToolCallMarker`) | every ⚠️/🛑/💥 |

The whack-a-mole feeling is correct, and it has a precise shape: **the same per-family knowledge is hand-maintained in (at least) three overlapping taxonomies, each re-deriving the same facts from the same Jinja template.**

- `PromptTemplate` (`Sources/ManifoldHardware/PromptTemplate.swift`) — 7 families (chatML/llama3/mistral/alpaca/gemma/gemma4/phi); owns rendering + `rendersToolsNatively` + a thinking-markers accessor. Only `.gemma4` renders tools.
- `ToolCallDialect` / `ToolCallDialectFamily` (`Sources/ManifoldHardware/ToolCallDialect.swift`) — hermes/qwen/gemma/llamaPythonTag/mistral, with delimiters + arg-encoding.
- A **second, duplicate** `ToolCallDialect` nested in `ChatTemplateToolDescriptor` (`Sources/ManifoldModelCatalog/`).
- Plus `ThinkingMarkers` (`Sources/ManifoldHardware/ThinkingMarkers.swift`) with its own name-substring + template-substring detection — three sniff implementations of one idea.
- Plus per-backend `ToolCallMarker` tables duplicated across **both** companions (`LlamaToolMarkers.swift` has 4 families, `MLXToolMarkers.swift` has 3 — Qwen/Llama/Mistral are coded twice).

**Adding one new model family today is 3–4 edits in 3 repos.** That is the cost function we are trying to change.

Three failure classes follow directly, and the matrix localises each:

1. **MLX injects tools as prose, not as structured data** — `MLXChatMessageEncoder.swift:238-305` **(companion)** hand-builds a text block ("You have access to the following functions…") and stuffs it into the system message, then calls `prepare(messages:)` with **no tools parameter**. swift-transformers' `applyChatTemplate(messages:tools:)` — the structured path — is bridged but never called with tools (`TransformersTokenizerLoader.swift:63-74`, companion). So Mistral's template never sees a structured `tools` field, never emits `[TOOL_CALLS]`, and the model answers in prose. **This is matrix finding F3.**
2. **llama.cpp render-refusal** — core's `JinjaPromptRenderer` prepended a `system` turn that Mistral's alternation-strict template rejected (fixed #2032/#2035). A render quirk, hand-handled.
3. **Constrain/parse drift** — generation is grammar-constrained (when wired) but parse-back is an independent per-family reverse-parser; the two representations can disagree. This is a *named* industry problem (vLLM issue [#27766](https://github.com/vllm-project/vllm/issues/27766)).

What MK already has right (do not re-litigate): the cloud/Ollama delegation, a real GBNF grammar builder (`ToolGrammarBuilder`) auto-derived in `GenerationQueue.swift:705-725`, real GBNF logit processors on **both** companions, `ChatTemplateToolDescriptor` + `RenderConsistencyChecker` (template-derived static claims), and — uniquely — a **measured** `ToolCallConformance` cache keyed `(model × quant × backend)`.

---

## 2. Comparative research: what mature projects actually do

### 2.1 Input rendering — settled everywhere

**Nobody hand-prompts tool specs per family anymore.** The unanimous answer is *the model's own chat template is the interface contract*, with tools passed as a **structured parameter**:

- **HuggingFace transformers** — `apply_chat_template(messages, tools=…)`; the model author ships the Jinja template that knows the trained format; `get_json_schema(func)` converts Python functions to the OpenAI `{name,description,parameters}` shape. The ["Tool Use, Unified"](https://huggingface.co/blog/unified-tool-use) thesis: extend chat templates to cover tools → one model-agnostic caller. *Load-bearing detail:* `arguments` must be a **dict**, not a JSON string; tool results use the `tool` role.
- **vLLM** — calls HF `apply_chat_template` with the request's `tools`; `--chat-template tool_use` selects the tool-use template. ([docs](https://docs.vllm.ai/en/stable/features/tool_calling/))
- **mlx-lm** — `tokenizer.apply_chat_template(messages, tools=…)` (`mlx_lm/server.py`); swift-transformers mirrors it. **MLX's bug is that MK bypasses this.**
- **llama.cpp** — minja renders the embedded Jinja (`--jinja`); ([function-calling.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)).
- **LM Studio / Jan** — both template-derived from the GGUF embedded Jinja; capability is "does the template support the `tool` role."

### 2.2 Output handling — the live frontier, and llama.cpp's keystone

This is where projects diverge, and where MK's drift lives.

- **vLLM** — a per-family **parser plugin registry**: `ToolParserManager` with `@register_module("name")`, lazy imports, a 2-method interface (`extract_tool_calls` + `extract_tool_calls_streaming`), ~40 families. Selection is **explicit** (`--tool-call-parser <name>`), never auto-detected. Parsers hard-code their delimiters (`Hermes2ProToolParser` literally has `tool_call_start_token = "<tool_call>"`). Constraint is **optional and `tool_choice`-driven**: `auto` → free-gen + parser; `required`/named → `adjust_request` compiles the tool's JSON schema into a grammar (`anyOf` over tools) and *forces* valid JSON. ([struct-decode-intro](https://blog.vllm.ai/2025/01/14/struct-decode-intro.html))
- **llama.cpp (the keystone)** — PR [#17136](https://github.com/ggml-org/llama.cpp/pull/17136): **one PEG definition per chat format emits *both* the GBNF grammar (constrain-side) and the runtime parser (parse-side)** — they are the same object, so they *cannot drift*. Family selection is two-tier: a hand-maintained dispatch string-matches ~10 quirky templates (GPT-OSS/Harmony, Gemma4, Functionary, Kimi K2…); everything else hits a **template-introspecting autoparser** that synthesises parser+grammar from the template itself. The old per-family enum is **gone**. Grammar is **lazy + trigger-gated** — engages only after a tool-open token, so prose under `tool_choice=auto` still works. (`common/chat.cpp`, `common/chat-peg-parser.cpp`, `docs/development/parsing.md`)
- **Ollama** — default path derives the tool-call prefix by walking the template AST (`tools/template.go` `parseTag`); a newer path adds hand-coded Go renderer+parser pairs for hard families (Qwen3-Coder, Harmony). Tool calling itself is **not** grammar-constrained (only the `format` JSON-schema param is).
- **mlx-lm** — `_infer_tool_parser(chat_template)` sniffs delimiters in the template to pick a parser module; **no grammar/constrained decoding at all** — the documented root cause of its empty-`tool_calls` issues (#1096, #1293).

### 2.3 Constrained decoding — "constrain, don't reverse-parse"

Every constrained-decoding library is built on one principle: *make invalid output impossible to generate rather than generate freely and parse afterward.* JSON-schema/grammar → compiled automaton → per-token logit mask (disallowed tokens → −∞).

- **Tool calling as a grammar** = a **discriminated union**: top-level `anyOf` over N tools; each branch pins `name` to a `const`/`enum` and constrains `arguments` to *that tool's* schema. **MK's `ToolGrammarBuilder` already emits exactly this shape.**
- **Ecosystem convergence:** **xgrammar** (precompute + adaptive mask cache; the default in vLLM, supported in SGLang/MLC) and **llguidance** (lazy Earley, ~50µs/128k-vocab, no startup cost; in vLLM/SGLang/llama.cpp/OpenAI). **No portable compiled-grammar IR exists** — each engine compiles to its own automaton. The *de-facto input standard* is **JSON Schema** (tool args) + **GBNF/EBNF** (grammar text) — both of which MK already speaks.
- **The named anti-pattern (vLLM [#27766](https://github.com/vllm-project/vllm/issues/27766)):** when the constraint grammar and the reverse-parser are maintained separately, they drift. The fix is to **derive one from the other**.
- **Pitfall (lm-format-enforcer):** over-rigid grammars that force exact whitespace/field-order push the model off-distribution and *increase* hallucination. Constrain structure + required fields; leave latitude on whitespace/ordering.
- **Pitfall (vLLM [#22132](https://github.com/vllm-project/vllm/issues/22132)):** a generic grammar can clobber a model's *native* tool-call format. The grammar must match the template's native wrapper.

### 2.4 Multi-backend packaging — the cohesive per-family object

For **local** models the field standard is **one cohesive per-family object** bundling template + call-syntax + parse-markers + grammar:

- **node-llama-cpp `ChatWrapper`** (closest to what MK wants) — a cohesive per-family object declares its formatting *as data* (a settings struct bundling system-message support, the function-call prefix/params/suffix, the result wrapper, and reasoning-segment markers; exact property names not independently verified — the *pattern* is the point). **The same prefix/suffix that *writes* a call is what *detects* it** — no separate parser. Extraction is grammar-constrained against the tool's JSON schema. Selected by template/architecture/token detection.
- **llama-cpp-python chat handler** — a callable bundling tool-prompt injection + grammar mode + output parser; registry by name; selection precedence `explicit → guess-from-GGUF-template → embedded-Jinja → fallback`.
- **LangChain / LiteLLM (cloud-aggregator pattern)** — OpenAI tool schema as lingua franca + thin per-provider adapters; capability via a **declared static table** (LiteLLM `model_prices…json`) whose maintainers *document its drift* as the central weakness and ship a runtime override. Declared tables are the answer for "100+ remote APIs you can't introspect," **not** for local models you can.

### 2.5 Apple FoundationModels / CoreAI — the purest expression of the principles

Apple's WWDC 2026 stack is the most relevant comparator because MK already ships a `ManifoldFoundation` backend and has dormant `CoreAI`/`SystemAIProviderExtension` build-trait stubs. Two layers:

- **CoreAI** is the *low-level tensor inference engine* (the Core ML successor) — `AIModel`, `InferenceFunction`, `NDArray`, Neural Engine / GPU dispatch. It has **no tool/chat/template concept at all**. ([Core AI framework](https://developer.apple.com/documentation/coreai/), [Meet Core AI — WWDC 324](https://developer.apple.com/videos/play/wwdc2026/324/))
- **FoundationModels** is the session/tool/structured-output layer *on top*. The bridge is `CoreAILanguageModel` (and `MLXLanguageModel`, both being open-sourced), which conform a custom engine to FoundationModels' `LanguageModel` protocol. ([What's new in Foundation Models — WWDC 241](https://developer.apple.com/videos/play/wwdc2026/241/))

Every principle this doc argues, Apple ships as the *only* option:

- **Tools are structured Swift types, never text.** `Tool` protocol = `name`/`description` + a `@Generable Arguments` type + `parameters: GenerationSchema` + `call(arguments:) async throws -> Output where Output: PromptRepresentable`. The framework drives a 6-phase tool loop and re-injects output — *"prevents the need for any manual string parsing."* ([Tool](https://developer.apple.com/documentation/foundationmodels/tool))
- **Guided generation IS grammar-constrained decoding at the sampler.** Verbatim: *"The framework uses **constrained sampling**… prevents the model from producing malformed output… **strong guarantees** that the response is in a format you expect."* `@Generable`/`@Guide` compile a type into a `GenerationSchema` that conditions the decoder — the same family as GBNF/outlines/xgrammar, just with the grammar hidden behind a Swift macro. Validates §3's constrain-don't-reverse-parse thesis outright. ([Guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation))
- **The chat template is fully hidden; a structured `Transcript` is the contract.** Apps compose `Instructions`/`Prompt`/`Transcript` entries (`.toolCalls`, `.toolOutput`, …); the dialect/template is the *provider's private concern*, surfaced only to provider implementers via the executor. This is exactly the `ChatProfile` seam — the dialect is internal, the structured transcript is the API. ([Transcript](https://developer.apple.com/documentation/foundationmodels/transcript))
- **The provider boundary = light descriptor + heavy executor + declarative capabilities.** `LanguageModel` (descriptor) + `LanguageModelExecutor` (receives the full `Transcript` + `GenerationOptions`/`ContextOptions` incl. **response schema**, streams typed `.textDelta`/`.toolCallDelta` events + does transcript→native translation) + `LanguageModelCapabilities([.toolCalling, .guidedGeneration, .reasoning])`. The framework checks capabilities and **throws `LanguageModelError.unsupportedCapability`** when a request (e.g. guided generation) can't be honored — *not* a silent degrade. This maps almost 1:1 onto MK's `InferenceBackend` + `BackendCapabilities` (+ `toolDialect` from #2029) + `GenerationEvent`. ([LanguageModelExecutor](https://developer.apple.com/documentation/foundationmodels/languagemodelexecutor), [LanguageModelCapabilities](https://developer.apple.com/documentation/foundationmodels/languagemodelcapabilities), [Bring an LLM provider — WWDC 339](https://developer.apple.com/videos/play/wwdc2026/339/))

**The correction for MK's trait stubs:** there is **no system-wide developer AI-provider extension point** (verified against WWDC 339 + the framework docs). Providers are plain Swift packages distributed by SPM and chosen per-app at `LanguageModelSession` init. (Apple separately offers consumer-facing Siri model-swapping, but that is not a developer registration API — this part is a design inference, not confirmed from the session content.) So MK's `SystemAIProviderExtension`/`CoreAI` stubs are **waiting for an OS API that did not ship** — what shipped is an *in-process protocol*. They should be repurposed (a `LanguageModel`/`LanguageModelExecutor` adapter target) or retired, not kept as "awaiting OS extension."

**What Apple does NOT cover (and MK must keep owning):** non-Apple + cross-platform backends (Ollama, cloud, GGUF/llama.cpp, MLX on n-1/Linux/older OS); an *explicit* grammar/dialect surface (Apple hides `GenerationSchema` + template because it talks to *one* model family — MK talks to many and must expose GBNF/Jinja/dialects); richer capability dimensions (Apple's set omits streaming/vision/context-window); and — crucially — the **measured conformance matrix**, which has *no Apple analogue* (Apple assumes the model honors the constraint; MK can't assume that across heterogeneous engines).

**Capability detection verdict:** local kits *derive* capability from the template (trustworthy negative, unreliable positive); cloud aggregators *declare* it (drifts); Apple *declares* a typed capability set and *throws* on violation (no measurement). **MK already has a fourth, strictly stronger layer none of them do: a *measured* verdict (`ToolCallConformance`).** The only gap is that MK's *derived* layer is scattered across three taxonomies instead of bundled.

---

## 3. Target architecture: `ChatProfile` + grammar-first + measured arbiter

Resolving the one productive tension in the research — llama.cpp/node-llama-cpp *bundle* everything into one object, while HF/vLLM *decouple* input-template from output-parser — the synthesis operates at two levels:

- **Knowledge locality (bundle):** all per-family facts live in **one** `ChatProfile` value (kills the 3-taxonomy scatter). This is node-llama-cpp's `ChatWrapper`.
- **Engine decoupling (separate):** input-render and output-handle stay distinct phases fed *from* that one profile (HF/vLLM's two-artifact discipline). Don't fuse the render and parse code paths.
- **Within the output side, one spec drives both grammar and parser** so they can't drift (llama.cpp's PEG, vLLM #27766's fix).

### 3.1 The `ChatProfile` descriptor — narrow, not a god-object

**Scope correction (post-review).** An earlier draft proposed one value type that "subsumes `PromptTemplate`, both `ToolCallDialect`s, `ChatTemplateToolDescriptor`, and `ThinkingMarkers`." The YAGNI review rightly killed that: those types span three modules at three lifecycle stages, have wildly different densities (`PromptTemplate` ~85% logic, `ToolGrammarBuilder` 100% logic, the conformance record ~95% data), and **don't cross-reference each other** — fusing them into one ~2,000-line value would be a god-object, and `ManifoldHardware` is a *leaf* module that cannot depend upward on `ManifoldModelCatalog`/`ManifoldInference` (CLAUDE.md boundary). Also corrected: the two `ToolCallDialect` types are **not accidental duplication** — `ManifoldHardware.ToolCallDialect` is the *canonical* dialect; the nested one in `ChatTemplateToolDescriptor` is the template-derived *claim*. They are deliberately layered (indeed `ToolCallConformance.observedDialect` is kept a `String` *specifically* "to stay decoupled from the `ToolCallDialect` type" — `ToolCallConformance.swift:82`).

So `ChatProfile` is a **narrow descriptor of the overlapping descriptive facts only** — not the engines, not the measured record. It lives in the leaf module (`ManifoldHardware`) and is *consumed by* the renderer and grammar builder, which stay separate:

```
ChatProfile  (descriptor — facts, not engines)
├── promptFamily / chatTemplateRaw ref   // WHICH template; the renderer (ManifoldInference) still owns rendering
├── supportsSystemMessages               // alternation-strict? (the #2032/#2035 logic, expressed as a fact)
├── outputDialect                        // family · open/close delimiters · argEncoding · extractability
├── thinkingMarkers                      // one detection pass, not three parallel tables
├── stopSequences                        // derived from the template's turn-closers (kills the #2008/#2019 class)
└── nativeToolsFlag                      // template-expressible (necessary-not-sufficient)
```

What it **does** unify: the *facts* currently triplicated across `PromptTemplate`'s thinking/stop accessors, the two `ToolCallDialect`s, and `ThinkingMarkers`. What it **must not** absorb: `JinjaPromptRenderer`/`ToolGrammarBuilder` (engines — they *read* the descriptor) or `ToolCallConformance` (the measured record — §3.5 keeps it a separate layer). The descriptor is the single source for "how does this family encode tool calls"; the engines and the measured arbiter consume it.

### 3.2 Resolution (derive, with overrides + graceful fallback)

`ChatProfile.resolve(from: GGUFMetadata/ModelInfo)` — **one parse of the template into one object**, replacing the parallel work in `PromptTemplateDetector` + `ChatTemplateToolDescriptor`:

1. **Hand-coded overrides** for a small set of quirky families (llama.cpp ships ~10; MK needs far fewer).
2. **Template introspection** as the primary path — derive delimiters/markers/stops from the embedded Jinja (round-trip a probe call through `JinjaPromptRenderer`, exactly as `RenderConsistencyChecker` already does).
3. **Architecture / lineage / filename** as fallbacks.
4. **Autoparser fallback** for unrecognised families → a best-effort derived dialect, **never a silent `nil`/no-tools** (llama.cpp + Ollama both degrade gracefully here; MK currently returns `nil`).

### 3.3 Generation: grammar-first, `toolChoice`-aware, lazy-gated

**Correction (post-review): this is plumbing-present, feature-absent — not "90% wired."** `GenerationQueue.swift:705-725` *does* auto-derive a grammar from the tool list when `supportsGrammarConstrainedSampling` is true. But `ToolGrammarBuilder` is **dialect-blind**: it emits a bare `{"name","arguments"}` envelope with an eager `prose-head ::= [^{]` escape and **no native wrapper** (`[TOOL_CALLS]`, `<tool_call>`, python-tag). For the exact failing matrix families (Mistral, Hermes, python-tag) this grammar *doesn't match the model's native format* — which is the #22132 clobber this doc warns against — and the **lazy/trigger-gated** mechanism does not exist. So this is real feature work (dialect-aware grammar + trigger-gating, derived from §3.1's `outputDialect`), borrowing vLLM's `adjust_request` discipline + llama.cpp's trigger-gating:

- `toolChoice == .required`/`.tool(name)` → constrain via grammar **derived from the same `outputDialect` spec** (not an independent grammar). Valid tool-call JSON becomes a *decoding guarantee* on capable backends.
- `toolChoice == .auto` → lazy/trigger-gated grammar (engages after the tool-open token) so prose still works; fall back to free-gen + parser.
- Constrain **structure + required fields**, leave latitude on whitespace/order (lm-format-enforcer's lesson). Match the template's native wrapper (avoid the #22132 clobber).

### 3.4 Parsing: one engine, fed from the profile, one canonical output

- `ToolCallTransform` / `OutputParserSession` read delimiters **from the profile's `outputDialect`**, not hand-built presets — eliminating the marker-drift `MarkerOverlap` exists to guard.
- All backends — cloud and local — normalise to **one canonical `ToolCall` type** (LangChain's lingua-franca discipline) so downstream is provider-agnostic.

### 3.5 Capability: measured arbiter layered over derived profile

Keep the two layers **separate** (don't merge profile into conformance):

- `ChatProfile` answers *"how does this family encode tool calls"* — template-derived, trustworthy-negative.
- `ToolCallConformance` (`Sources/ManifoldRuntime/Services/ToolCallConformance.swift`, keyed `model × quant × backend`, `source: templateExpressible → renderConsistent → measured`) answers *"does this checkpoint actually tool-call."*
- The measured verdict can **downgrade** the constrain path to free-gen+parse when soaks say the grammar path is unreliable, and can **seed** the profile's dialect from the *observed* emitted format. This makes MK's empty-`tool_calls` failure mode *recoverable* — which mlx-lm's and LiteLLM's are not.

### 3.6 Borrow Apple's request/capability discipline

Two refinements from FoundationModels that tighten the seams above:

- **Schema as a first-class request input that throws, not a claim that hopes.** Apple flows the response schema into the executor via `ContextOptions` and *throws* `unsupportedCapability(.guidedGeneration)` when it can't be honored. MK should treat `GenerationConfig.grammar`/`structuredOutput` the same way: a backend that's handed a grammar it can't satisfy throws (`InferenceError.unsupportedGrammar` already exists — `InferenceBackend.swift:294`), never silently ignores. This is cleaner than the current claims-then-hope shape.
- **Declarative, checked capability set.** Mirror `LanguageModelCapabilities([.toolCalling, .guidedGeneration, …])` on `BackendCapabilities` (which already carries `toolDialect` from #2029) and gate dispatch on `capabilities.contains(…)` before sending — Apple's pre-flight check pattern.

---

## 4. Principles to adopt (the durable shape)

1. **The chat template is the interface contract.** Derive per-family facts from it; render through the model's own template with structured `tools`. Hand-coding per family is the anti-pattern the whole field has abandoned for local models.
2. **Constrain, don't reverse-parse.** On grammar-capable backends, a grammar makes valid output a decoding guarantee; the parser is a *net*, not the primary mechanism.
3. **One dialect spec drives both grammar and parser.** They cannot drift if they share a source (llama.cpp PEG; the cure for vLLM #27766).
4. **Bundle per-family knowledge in one `ChatProfile`.** One object per model, not three overlapping taxonomies in three repos.
5. **Measure, don't assume.** `ToolCallConformance` is the arbiter; derived/declared claims are necessary-not-sufficient.
6. **Decouple input-render from output-parse as engine phases; normalise to one canonical `ToolCall`.**
7. **Delegate to the runtime wherever it exists.** Ollama/cloud already do render+parse server-side; that's *why* they're clean. Own the minimum. (Apple takes this furthest — the framework owns the whole tool loop.)
8. **Degrade gracefully where you can't satisfy a request, but throw where you can't — never silently ignore.** Template-introspecting autoparser fallback + measured downgrade for *parsing*; but a grammar/schema a backend can't honor should *throw* (Apple's `unsupportedCapability` discipline), not be dropped.

---

## 5. Phased migration (what, where, cost)

**Precondition (do before scheduling any phase).** Re-run the conformance matrix on `origin/main`, not this branch. The cited matrix predates #2032/#2035, and the MLX-Mistral cell (F3) that justifies Phase 0 is explicitly flagged *"re-measure pending."* The entire evidence base must be re-measured before committing — do not build on provisional cells. (See [feedback: planning base staleness] — audit against `origin/main`, not a stale local checkout.)

**Phasing reality (post-review).** The repo policy is *"no phased feature splits — ship a feature as one PR."* Phases 1–3 are genuinely interdependent (Phase 2's grammar derives *from* Phase 1's descriptor; Phase 3 seeds *the* dialect) — they are **not** independently shippable as the earlier table implied, and a public-type change in core (`ChatProfile`) reaches both companions, which pin core `.upToNextMinor` and are currently on **different** core minors (manifold-llama 0.59.0, manifold-mlx 0.60.0). A type rename/removal has **no `@unknown default` escape**, so it must go *additive-then-delete across two core minors* with a mandatory `companion-compat.yml` run before each. Realistic cost is **~10–12 PRs across 3 repos**, not 5. Track under the existing open umbrella **#2005** (*measured tool-call conformance matrix, supersedes #2001*) — **not** #753, which is closed; do not open per-phase issues.

| Phase | Change | Repos | Realistic cost | Value |
|---|---|---|---|---|
| **0 — MLX structured tools (ADDITIVE)** | Thread structural `tools` into `applyChatTemplate(messages:tools:)` **in addition to** the existing prose block, *not* as a replacement. Make `supportsToolCalling` conditional on `dialect != .unknown` (bundle this in — it's a latent bug). Gate the per-family cutover on a **live `manifold-tools-mlx` soak**. **Do NOT remove the Llama prose block** — it deliberately steers Llama off its native `<\|python_tag\|>` (which the MLX detokenizer drops, issue #59); a pure structural render *regresses* the currently-✅ `llama32-3b` cell. Templateless models also lose tool instructions if the prose path is removed. | manifold-mlx | **Med** (3–4 files + a **new render-side golden test that doesn't exist yet** + a live MLX re-soak to prove no regression) | **High** — recovers MLX-Mistral (F3) once re-measured; additive so low blast radius. |
| **1a — adjudicate the taxonomy contradictions** | Write the cross-taxonomy parity test **first**; it goes *red* (the Gemma delimiter contradiction is a real existing bug). Adjudicate each disagreement against real-template ground truth. This is **behaviour-*defining*, not preserving** — there is no single correct behaviour today. | core | **Med** | **High** — establishes the ground truth Phase 1b needs; surfaces latent bugs. |
| **1b — `ChatProfile` descriptor (additive)** | Introduce the narrow descriptor (§3.1); `resolve(from:)` once; feed existing engines. Land **additively**, deprecate old accessors in place; delete in a *later* core minor after companions migrate. Respect the `ManifoldHardware` leaf boundary. | core (+ companion bumps) | **Med–High** (28 `PromptTemplate` files / 8 modules; persisted in 4 SwiftData schema versions → migration concern; 2-core-minor additive-then-delete dance) | **High** — kills the 3-edit-per-family cost function. |
| **2 — dialect-aware grammar + parser from one spec** | Make `ToolGrammarBuilder` dialect-aware (emit the native wrapper from `outputDialect`), add lazy/trigger-gating, derive the `ToolCallMarker` set from the same spec, add the template-introspecting autoparser fallback. **Net-new feature work** (not a wiring refinement — see §3.3). Mind GBNF rule-name hyphens (companions' parsers reject `_`). | core + manifold-llama | **High** | **High** — removes constrain/parse drift (#27766); closes the llama.cpp reverse-parse gap. |
| **3 — measured arbiter + cross-process write-path** | Let `ToolCallConformance` downgrade constrain→free-gen and seed the dialect. **The real blocker is an unbuilt serialization boundary**, not "finishing #2034": companion `ManifoldRuntime`/`ManifoldPersistenceSwiftData` are **test-target-only** deps, so a companion soak *cannot reach* core's SwiftData cache. Spike the design first — recommend **soak emits JSONL → core-side importer upserts** (matches the existing `manifold-tools score` file flow; keeps SwiftData in core). | core + companions | **Med–High** | **Med** — makes empty-`tool_calls` recoverable. SwiftData migration = human-reviewed PR. |
| **4 — delegate the llama.cpp leg** *(optional, deepest)* | Rebuild the xcframework to include `common/chat.cpp` + minja (or run `llama-server` like Ollama). Deletes the in-Swift render+parse for the llama leg. | manifold-llama (packaging) | **High** | **Highest structural** — converts the messiest leg into a clean delegated one. Separate decision; currently a non-goal. |
| **5 — Apple `LanguageModel` adapter** *(SDK-gated)* | Once iOS 27/macOS 27 is the n-1 floor, conform MK backends to Apple's `LanguageModel`/`LanguageModelExecutor`. **Repurpose the dormant `CoreAI`/`SystemAIProviderExtension` stubs** (no OS extension exists to bind them to — §2.5). | core / ManifoldFoundation | **Med** | **Med** — the realistic payoff of the CoreAI stub work; SPM-distributable. |

**Honest near-term recommendation.** Don't commit the whole table. The defensible near-term scope is: **(a) re-measure the matrix on `origin/main`; (b) Phase 0 as an additive, soak-gated MLX change with a new golden test; (c) Phase 1a — write the parity test and adjudicate the contradictions.** Re-evaluate Phases 1b–3 only *after* the re-measured matrix shows how many real failures remain — several matrix failures (gemma renders-no-call) are *model* facts no architecture fixes, so the post-Phase-0 failure count may not justify the full consolidation.

---

## 6. Risks, caveats, and non-goals

**Risks / caveats:**
- **swift-jinja can't render every template — but this hole is SMALL** (the one attack the doc survived cleanly). The #1811 spike confirmed swift-jinja renders every mainstream chat template (Qwen/Llama/Mistral/Gemma/Hermes/Phi, vision, RAG), byte-exact against `transformers.apply_chat_template`; its unsupported list is HTML/web features absent from chat templates. The two cited "failures" aren't engine gaps — #1966 was a whitespace-fidelity bug (fixed), and the Mistral alternation refusal was an MK usage bug (fixed #2032/#2035). The 7-family enum fallback **stays necessary only for a small templateless tail** — it should *shrink*, never grow a new per-family arm. (`PromptRenderer.swift` already *throws* rather than ship a tool-less prompt when tools are requested and the enum can't render them — the right discipline.) Audit the fallback surface against `origin/main`, not this branch.
- **No portable grammar IR.** Keep MK's own `ToolGrammarBuilder`; align to the *input* standard (JSON Schema for args, GBNF/EBNF text) — do **not** attempt to adopt xgrammar/llguidance engines (C++/Rust, wired into Python servers; nothing to bind to in Swift).
- **MLX has no grammar hook for the Mistral `[TOOL_CALLS]` wrap yet** (`MLXBackend.swift:583-589`, companion, marked "follow-up"). Leave the reverse-parse net on that leg until it lands.
- **Don't over-constrain.** Rigid whitespace/ordering grammars increase hallucination (lm-format-enforcer). Match the template's native wrapper to avoid the Qwen3-style clobber (#22132).
- **Cross-repo write-path for measured cells (Phase 3)** is the historical derail risk — the artifact lives in core but soaks run in three repos. Spike the write-path before building.
- **`ChatProfile` consolidation must be behaviour-preserving** — land it behind parity tripwire tests against the current taxonomies before deleting them. Behaviour-change-without-test-sweep has gone CI-red before.
- **The `CoreAI`/`SystemAIProviderExtension` trait stubs have no OS API to bind to** (§2.5). Apple shipped an *in-process* `LanguageModel` protocol distributed by SPM, not a system-wide provider extension. Don't keep these stubs as "awaiting OS API" — repurpose (Phase 5 adapter) or retire. Verify against the iOS 27/macOS 27 GA SDK before acting.

**Non-goals:**
- Replacing the measured `ToolCallConformance` layer (it's the part MK does *better* than every project surveyed).
- A general local-evals platform — scope is tool-calling.
- Rewriting the cloud legs — they're already the clean, delegated reference.
- Forcing grammar on MLX's Mistral path before the companion wrap exists.

---

## 7. Testing strategy & shift-left

The adversarial review (see top) exposed the real testing gap: today the **live conformance matrix is the only signal**, so every render/parse/grammar regression needs a multi-hour Apple-Silicon soak to detect — and there is **no render-side golden test in manifold-mlx** at all. That is fully right-shifted. This refactor is only safe if testing moves left *with* it.

### 7.1 The reframe: one empirical question, everything else is deterministic

The matrix conflates two questions; only the second needs weights:

- **Deterministic (no model):** does the prompt render correctly? does the grammar match the dialect's native wrapper? does `ToolCallTransform` parse this family's output? does the derived `ChatProfile` match the template? — reproducible from fixtures, in milliseconds.
- **Empirical (needs weights):** does *this checkpoint* actually emit a tool call, and at what decoy ceiling? — the irreducible soak.

Shift-left = pull the first category into per-PR tests and shrink the soak to the second. (The conformance doc already hinted at this — it called the #1909 render-drop class *"statically diffable."*)

### 7.2 The pyramid

| Layer | What it tests | Model? | Per-PR CI? | Catches (matrix class) |
|---|---|---|---|---|
| **0 — Type/compile** | Exhaustive switches over dialect family / `GenerationEvent` / capabilities; all-traits build sweep. A new family **won't compile** until every facet is filled. | no | yes (free) | "forgot to handle family X" |
| **1a — Render goldens** | Per (family × template): rendered prompt **byte-exact** vs a checked-in golden, oracle'd against `transformers.apply_chat_template`. | no | yes | tool-block dropped (#1909), alternation-fold wrong (#2032), whitespace drift (#1966), **MLX tools-as-prose (F3)** |
| **1b — Dialect derivation** | Given a template fixture, `ChatProfile.resolve()` yields the expected dialect / markers / stop-sequences. | no | yes | the **Gemma-delimiter contradiction**; "classified differently by each taxonomy" |
| **1c — Grammar accept/reject** | GBNF well-formed (hyphen rule-names — catches the *CI-can't-compile-GBNF* trap); known-good outputs **accepted**, malformed **rejected**; native wrapper present. | no | yes | dialect-blind grammar; the #22132 clobber |
| **1d — Parse-back fixtures** | Per-family raw output replayed through `ToolCallTransform` → asserts the right `ToolCall`. Same dialect spec as 1c, opposite direction. | no | yes | parser/grammar drift (#27766) |
| **2 — Mock-backend turn-loop** | `MockInferenceBackend` scripted to emit a family's bytes → full dispatch loop extracts + calls. Contract: claim `supportsToolCalling` ⇒ pass a round-trip; handed a grammar it can't honor ⇒ **throws** (Apple's `unsupportedCapability` discipline). | no (mock) | yes | integration drift (#2026), capability over-claim (MLX `.unknown`) |
| **3 — Static render-consistency** | `RenderConsistencyChecker` promoted to a **gate** over template fixtures: template claims dialect X ⇒ renderer emits X. | no | yes | the (a)-class the matrix described |
| **4 — Live conformance soak** | *Only* the empirical question: does this checkpoint tool-call, decoy ceiling. The matrix + `ConformanceScorer`. | **yes** | **no — scheduled/local** | weights facts (gemma renders-no-call) |

Layers 0–3 fold into the existing test target → **~zero marginal CI runs**. On macOS 10× billing that is the point: catch it in 30s locally, not a red multi-hour soak. Layer 4 stays where `scripts/local-integration-sweep.sh` already lives (scheduled, not per-PR).

### 7.3 The keystone: one per-family fixture corpus, three consumers

A **fixture per family** = `{ chat template, sample tool-call output, expected ToolCall, expected rendered prompt }`. That single artifact feeds the render golden (1a), the grammar accept/reject (1c), and the parse-back (1d) — which **is** the "one spec drives both grammar and parser" principle (§3.4), expressed as a test. Adding a new family's fixture becomes the **required first step of any new-family PR**, forcing the per-family work left into a deterministic artifact instead of discovering it in production.

Two cheap bootstraps (so this is harvest, not greenfield authoring):
- **Mine the matrix's own JSONL transcripts** — the last soak already captured real per-family model output (the ~12 MB transcripts pruned from `20260622-232839`, regenerable). That is the parse-back + sample-output corpus, for free.
- **Oracle render goldens against `transformers`** via the `regenerate.py` + `uv` flow already proven in the swift-jinja byte-match work (the #1966 fix). Established pattern, not new infra.

### 7.4 Build on what exists — this is assembly, not a rebuild

| Already exists | Gap to close |
|---|---|
| `RenderConsistencyChecker` (#2022) | promote to a gate over a template-fixture set |
| `ConformanceScorer` + `ScenarioRunner` (`ManifoldTools`) | extend scenarios to deterministic per-family replay (Layer 2) |
| `MockInferenceBackend`, `BackendContractChecks` | add the tool-round-trip + grammar-throws contract |
| transformers byte-match goldens (core, swift-jinja) | extend to companions; **no render golden exists in manifold-mlx** |
| matrix JSONL transcripts | turn into the checked-in fixture corpus |

### 7.5 Woven into the migration, not a trailing phase

This is what makes each phase safe and directly dissolves the review's top objections:

- **Phase 0's "needs a live soak to prove no regression"** → build the Layer-1a render golden *first*; the structural-tools change is then provably safe deterministically, and the soak only confirms. This is the concrete answer to "don't regress the ✅ `llama32-3b` cell."
- **Phase 1a's "no ground truth to preserve"** → the adjudicated contradictions (Gemma delimiter, etc.) get **encoded as Layer-1b goldens**. That converts "there is no correct behaviour today" into "the fixture corpus *defines* correct behaviour," and consolidation becomes "produce the same goldens."
- **Phase 2's dialect-aware grammar** → gated by Layer-1c accept/reject before any model runs.

**Test conventions (per CLAUDE.md / `Tests/README.md`):** XCTest for new tests (match Swift Testing in existing files); a test that hits SwiftData (the conformance cache) is an *integration* test — name/place it so; no `MockURLProtocol.reset()` across suites; the fixture-corpus suites are deterministic and CI-safe, so they run under the standard `scripts/test.sh --profile local` gate, while the Layer-4 soak stays out of per-PR CI.

---

## References

**MK code (this repo unless marked companion):** `Sources/ManifoldHardware/PromptTemplate.swift`, `…/ToolCallDialect.swift`, `…/ThinkingMarkers.swift`; `Sources/ManifoldModelCatalog/` `ChatTemplateToolDescriptor`; `Sources/ManifoldContract/ToolCallTransform.swift`; `Sources/ManifoldInference/Services/{JinjaPromptRenderer,PromptRenderer,ToolGrammarBuilder,RenderConsistencyChecker,GenerationQueue}.swift`; `Sources/ManifoldRuntime/Services/ToolCallConformance.swift`; `Sources/ManifoldOllama/OllamaBackend.swift`. **(companion)** manifold-mlx `MLXChatMessageEncoder.swift`, `MLXBackend.swift`, `TransformersTokenizerLoader.swift`, `MLXToolMarkers.swift`; manifold-llama `LlamaToolMarkers.swift`.

**Prior MK work:** matrix `docs/plans/archive/runs/20260622-232839/MATRIX.md`; issue #2005; PRs #2009 (template claim), #2022 (render-consistency), #2029 (dialect on caps), #2030 (conformance port+cache), #2032/#2035 (Mistral alternation fold), #2034 (SwiftData adapter), #1992/#2025 (JSON-Schema→GBNF).

**External:**
- llama.cpp: [`common/chat.cpp`](https://github.com/ggml-org/llama.cpp/blob/master/common/chat.cpp), [function-calling.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md), PR [#17136](https://github.com/ggml-org/llama.cpp/pull/17136)
- Ollama: [`tools/template.go`](https://github.com/ollama/ollama/blob/main/tools/template.go), [`model/parsers`](https://github.com/ollama/ollama/blob/main/model/parsers/parsers.go)
- mlx-lm: [`mlx_lm/tokenizer_utils.py`](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/tokenizer_utils.py) (`_infer_tool_parser`), issues [#1096](https://github.com/ml-explore/mlx-lm/issues/1096)/[#1293](https://github.com/ml-explore/mlx-lm/issues/1293)
- vLLM: [`tool_parsers`](https://github.com/vllm-project/vllm/tree/main/vllm/tool_parsers), [struct-decode-intro](https://blog.vllm.ai/2025/01/14/struct-decode-intro.html), [tool-calling docs](https://docs.vllm.ai/en/stable/features/tool_calling/), issues [#27766](https://github.com/vllm-project/vllm/issues/27766), [#22132](https://github.com/vllm-project/vllm/issues/22132)
- HF transformers: [unified-tool-use](https://huggingface.co/blog/unified-tool-use), [chat_extras](https://huggingface.co/docs/transformers/chat_extras), [chat_response_parsing](https://huggingface.co/docs/transformers/chat_response_parsing)
- Constrained decoding: [outlines](https://github.com/dottxt-ai/outlines) (arXiv [2307.09702](https://arxiv.org/abs/2307.09702)), [xgrammar](https://github.com/mlc-ai/xgrammar) (arXiv [2411.15100](https://arxiv.org/abs/2411.15100)), [llguidance](https://github.com/guidance-ai/llguidance), [lm-format-enforcer](https://github.com/noamgat/lm-format-enforcer), *Don't Fine-Tune, Decode* (arXiv [2310.07075](https://arxiv.org/abs/2310.07075))
- Multi-backend: [node-llama-cpp ChatWrapper](https://node-llama-cpp.withcat.ai/guide/chat-wrapper), [llama-cpp-python chat formats](https://github.com/abetlen/llama-cpp-python/blob/main/llama_cpp/llama_chat_format.py), [LangChain tool calling](https://python.langchain.com/docs/how_to/tool_calling/), [LiteLLM model-cost incident](https://docs.litellm.ai/blog/model-cost-map-incident)
- Apple: [Core AI](https://developer.apple.com/documentation/coreai/), [FoundationModels](https://developer.apple.com/documentation/foundationmodels/), [Tool](https://developer.apple.com/documentation/foundationmodels/tool), [Guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation), [LanguageModelExecutor](https://developer.apple.com/documentation/foundationmodels/languagemodelexecutor), [LanguageModelCapabilities](https://developer.apple.com/documentation/foundationmodels/languagemodelcapabilities); WWDC 2026 [241](https://developer.apple.com/videos/play/wwdc2026/241/) / [324](https://developer.apple.com/videos/play/wwdc2026/324/) / [339](https://developer.apple.com/videos/play/wwdc2026/339/)
