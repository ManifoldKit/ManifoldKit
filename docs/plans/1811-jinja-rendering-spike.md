# Spike: render GGUF-embedded Jinja chat templates (issue #1811)

**Status:** Spike / investigation only. No production code, no dependency adopted in `Package.swift` this round. This doc captures evidence + a recommendation so the impl PR can be budgeted and scoped.

**Date:** 2026-06-14
**Author:** worker spike off `origin/main` (`34aa2657`)

---

## 1. The gap, restated against the actual code

ManifoldKit never renders a model's real chat template. The flow for a GGUF model that
sets `requiresPromptTemplate: true` (only llama.cpp does) is:

1. `PromptTemplateDetector.detect(from:)`
   (`Sources/ManifoldHardware/PromptTemplateDetector.swift`) reads the GGUF
   `tokenizer.chat_template` string and **pattern-matches** it onto one of seven
   hardcoded enum cases (`chatML`, `llama3`, `mistral`, `alpaca`, `gemma`,
   `gemma4`, `phi`). The Jinja text is used only as a fingerprint — it is then thrown away.
2. `GenerationQueue` formats the prompt with the hand-rolled formatter
   (`Sources/ManifoldInference/Services/GenerationQueue.swift:439-446`):

   ```swift
   if backend.capabilities.requiresPromptTemplate {
       let template = selectedPromptTemplate   // a PromptTemplate enum case
       if backend.capabilities.supportsToolCalling && !config.tools.isEmpty {
           assembledPrompt = template.format(messages: flattened, systemPrompt: systemPrompt, tools: config.tools)
       } else {
           assembledPrompt = template.format(messages: flattened, systemPrompt: systemPrompt)
       }
   }
   ```
3. `PromptTemplate.format(...)` (`Sources/ManifoldHardware/PromptTemplate.swift`)
   emits a bespoke approximation (`formatChatML`, `formatLlama3`, …). For every
   case except `.gemma4` the `tools` argument is **ignored entirely**.

The silent-correctness hazard: a model whose real Jinja template diverges from the
hardcoded approximation gets the wrong prompt with no error and no log — degraded output
that looks like a "dumb model," not a bug.

---

## 2. Verification — is the mismatch real? **YES. Confirmed against two models on this machine.**

Both templates were extracted from real GGUF metadata (`tokenizer.chat_template`) on disk,
then rendered with `swift-jinja` (HF's real Jinja engine) and diffed against the enum output
for identical inputs. The render harness lived in a throwaway `/tmp/jinja-spike` package
(NOT added to ManifoldKit).

### Model A — Qwen3.5 4B (Ollama blob; arch `qwen35`) → detector picks `.chatML`

The embedded template contains `<|im_start|>`, so `detect(fromChatTemplate:)` returns `.chatML`.
But the real template does three things `formatChatML` does not.

**Inputs:** system "You are a helpful assistant.", user "What is the weather in Paris?",
one tool `get_weather`, `add_generation_prompt: true`.

**Real Jinja render (with tools):**
```
<|im_start|>system
# Tools

You have access to the following functions:

<tools>
{"function":{"description":"Get current weather","name":"get_weather","parameters":{...}},"type":"function"}
</tools>

If you choose to call a function ONLY reply in the following format with NO suffix:

<tool_call>
<function=example_function_name>
<parameter=example_parameter_1>
value_1
</parameter>
...
</tool_call>
... (IMPORTANT reminder block) ...

You are a helpful assistant.<|im_end|>
<|im_start|>user
What is the weather in Paris?<|im_end|>
<|im_start|>assistant
<think>
```

**Enum `.chatML` render (same inputs — `tools` arg is dropped on the floor):**
```
<|im_start|>system
You are a helpful assistant.<|im_end|>
<|im_start|>user
What is the weather in Paris?<|im_end|>
<|im_start|>assistant
```

**Diff / impact:**
- The entire `# Tools` declaration + the model-specific `<tool_call>/<function=…>/<parameter=…>`
  call-format spec is **missing**. The model was trained to emit that XML tool syntax; without
  the spec in the prompt it has no idea what format to produce. **Tool calling is silently broken.**
- The generation prompt suffix differs: real template ends `<|im_start|>assistant\n<think>\n`
  (primes the reasoning block — this is a thinking model). The enum ends at
  `<|im_start|>assistant\n`. The reasoning block is never opened by the prompt.
- (ManifoldKit injects tool descriptions for ChatML via `ToolSystemPromptBuilder` into the
  system prompt instead — but that is ManifoldKit's *own* generic format, not the model's
  trained `<tool_call>` syntax, so the model still sees the wrong calling convention.)

### Model B — Llama 3.1 8B (Ollama blob symlinked into `~/Documents/Models/`) → detector picks `.llama3`

The embedded template contains `<|start_header_id|>`, so the detector returns `.llama3`.

**Real Jinja render (no tools):**
```
<|begin_of_text|><|start_header_id|>system<|end_header_id|>

Cutting Knowledge Date: December 2023
Today Date: 26 Jul 2024

You are a helpful assistant.<|eot_id|><|start_header_id|>user<|end_header_id|>

Hello<|eot_id|><|start_header_id|>assistant<|end_header_id|>
```

**Enum `.llama3` render (same inputs):**
```
<|begin_of_text|><|start_header_id|>system<|end_header_id|>

You are a helpful assistant.<|eot_id|><|start_header_id|>user<|end_header_id|>

Hello<|eot_id|><|start_header_id|>assistant<|end_header_id|>
```

**Diff / impact:**
- Missing `Cutting Knowledge Date: December 2023` / `Today Date: …` lines that the
  official Llama 3.1 template *always* injects into the system turn. Llama 3.1 was trained
  with these present; dropping them is an out-of-distribution system turn.
- With tools, the real template additionally emits `Environment: ipython` in the system turn
  and an entire synthetic user message ("Given the following functions, please respond with
  a JSON for a function call …" + each tool as `tojson(indent=4)`). The enum emits none of this.

### Headline finding

**The mismatch is real, reproducible, and affects two of the most common local models a
ManifoldKit user will run (Qwen3.x and Llama 3.1).** The worst case is tool calling: the
enum silently discards the `tools` argument for every template except `.gemma4`, so any
tool-capable GGUF that isn't Gemma 4 is being driven with ManifoldKit's generic tool-prompt
convention rather than the syntax the model was actually trained on.

---

## 3. swift-jinja experiment (throwaway, outside the repo)

Scaffold (in `/tmp/jinja-spike`, discarded):

```swift
// swift-tools-version: 6.0
.package(url: "https://github.com/huggingface/swift-jinja.git", from: "2.0.0")
// product: .product(name: "Jinja", package: "swift-jinja")
```

Render call (the entire integration surface is this small):

```swift
import Jinja
let tpl = try Template(chatTemplateString)          // Template(_:with:) — Hashable, Sendable
let out = try tpl.render([                            // [String: Jinja.Value]
    "messages": messagesValue,
    "tools": toolsValue,
    "add_generation_prompt": true,
    "bos_token": "<|begin_of_text|>"
])
```

`Jinja.Value` is `Decodable` and has `ExpressibleBy*Literal` conformances, so message/tool
arrays decode straight from JSON — no manual AST construction. Both templates rendered
correctly on the first try, including macros (`render_content`), namespaces, `tojson`,
`reject`/`join` filters, and `raise_exception`.

### Packaging note discovered during the experiment

- In **swift-transformers 1.x**, `Jinja` is no longer a sub-target of swift-transformers; it
  was extracted into its **own package `huggingface/swift-jinja`** (resolved here at **2.3.6**),
  which swift-transformers 1.3.3 re-exports.
- Depending on `swift-transformers` just to get `Jinja` drags in a large graph
  (swift-nio, swift-crypto, swift-huggingface, EventSource, swift-collections, …).
- Depending on **`swift-jinja` directly** pulls in only **swift-jinja + swift-collections**.
  `swift-collections` is **already** in ManifoldKit's `Package.resolved`. So the marginal new
  top-level dependency is exactly one package.

---

## 4. Placement decision

**Recommendation: render in core, in `ManifoldHardware`, alongside `PromptTemplate` and the
detector. Do NOT put the renderer in the companion packages.**

Rationale, against CLAUDE.md's layering rules:

1. **The formatting call site is in core, not the companions.** `LlamaBackend` explicitly
   delegates formatting "externally by `InferenceService` using the detected `PromptTemplate`"
   (`manifold-llama/.../LlamaBackend.swift:16`); the actual `template.format(...)` call is
   `GenerationQueue.swift:442` in `ManifoldInference`. The companion produces tokens from a
   pre-assembled string — it never formats. Putting the renderer in the companion would
   require inverting that ownership.
2. **`PromptTemplate`, `PromptTemplateDetector`, GGUF parsing, and `ThinkingMarkers` all
   already live in `ManifoldHardware`** — the zero-dependency leaf. The renderer is the same
   layer of concern (turn messages → a prompt string for a templateless backend).
3. **Companions depend *up* into this package** (`manifold-llama` depends on
   `ManifoldHardware`), so a core renderer is automatically available to them; the reverse
   (core reaching into a companion) is forbidden.
4. **Cloud/MLX/Foundation backends don't need it** and won't pay for it: the renderer is only
   invoked behind `capabilities.requiresPromptTemplate`, which only llama.cpp sets. MLX already
   renders chat templates internally via `MLXLMCommon` (and manifold-mlx already has
   `swift-transformers`, hence `Jinja`, transitively — so even if we ever wanted MLX-side
   rendering it would cost zero new deps there).

**Dependency-edge check (the trap to avoid):** `ManifoldHardware` is currently a
**zero-dependency leaf** (CLAUDE.md: "Zero deps"). Adding `swift-jinja` to it makes it a
one-external-dependency leaf. That is acceptable and still leaf-shaped (it has no *upward*
ManifoldKit deps), but it is a real change to the module's contract — the impl PR must update
the CLAUDE.md target table entry for `ManifoldHardware` and the `PackageTraitGateAuditTest`
expectations if any pin the leaf's dep set. This edge is a **consumer→library** edge from
`ManifoldHardware` sources that will `import Jinja` unconditionally; it is NOT trait-gated
(there are no default traits since v0.48, and prompt rendering is core behavior).

If keeping `ManifoldHardware` strictly zero-dep is judged more valuable than co-location, the
fallback placement is `ManifoldInference` (which already has many deps and owns the call
site). `ManifoldHardware` is preferred for cohesion; `ManifoldInference` is the safe second
choice. **Do not** place it in `ManifoldContract` (the kernel must stay thin) or in the
companions (wrong layer, as above).

---

## 5. Dependency-adoption cost (resolve-check / cache-key budget)

Adding any new external package is a known local-gate blind spot (per memory:
"resolve-check is a local-gate blind spot"). Budget the impl PR for:

- **`Package.resolved` churn.** Adding `swift-jinja` adds its own pin **plus** any transitive
  pins it introduces. From the experiment the transitive set is just `swift-collections`
  (already pinned here) — so expect **+1 to +2 entries** in `Package.resolved`. Run
  `swift package resolve && git diff Package.resolved` locally before pushing; **do not stage
  `Package.resolved`** as a side effect of an unrelated edit (memory: never stage
  Package.resolved; #1429/#1432). The resolved file *will* legitimately change here, so this
  PR is the one place it's correct to commit it.
- **`resolve-check` CI job.** It re-resolves against the committed manifest; a new dep edge can
  surface a version-solver conflict that `swift build` locally doesn't (e.g. swift-collections
  range overlap with AnyLanguageModel / swift-huggingface). Run `swift package resolve` on a
  clean checkout (`scripts/clean-build.sh` if state desyncs) before pushing.
- **CI `.build/checkouts` cache key.** Per CLAUDE.md, the dependency cache
  (`.build/artifacts` / `.build/checkouts` / `.build/repositories`) is the cached tier. A new
  package invalidates that cache on first run → one cold clone + build of swift-jinja for the
  PR. swift-jinja is pure Swift (no xcframework), so the clone/compile cost is small relative
  to the ~100 MB llama.cpp xcframework already cached. Expect one slower CI run, then steady state.
- **`swift-tools-version` ceiling.** swift-jinja 2.3.6 builds under Swift 6.x; confirm its
  manifest tools-version ≤ the installed Xcode toolchain (Swift 6.2.x) before pinning, or
  `resolve-check`/`fuzz` break.

---

## 6. Concrete impl-PR plan

Ship as **one PR** (CLAUDE.md: one feature = one PR; tests + docs included).

1. **Add the dependency.**
   - `Package.swift`: `.package(url: "https://github.com/huggingface/swift-jinja.git", from: "2.x")`
     (pin the exact minor verified in CI). Add `.product(name: "Jinja", package: "swift-jinja")`
     to the `ManifoldHardware` target only.
   - Commit the resulting `Package.resolved` change deliberately (it's the legitimate exception).

2. **Plumb the raw template text to the call site (the real plumbing gap).**
   Today only the *detected enum case* (`selectedPromptTemplate`) reaches `GenerationQueue`,
   not the original `tokenizer.chat_template` string. The detector reads it and discards it.
   - Capture the raw chat-template string at detection time (it's already parsed in
     `GGUFMetadataReader` / `metadata.chatTemplate`) and carry it alongside the enum into the
     lifecycle/generation state (e.g. a new optional `resolvedChatTemplate: String?` on the
     model-lifecycle path that feeds `GenerationQueue`).

3. **Add a renderer in `ManifoldHardware`.**
   - New type e.g. `JinjaChatTemplateRenderer` that wraps `try Template(_:)` + `render(_:)`.
   - Map ManifoldKit's `(role, content)` messages + `[ToolDefinition]` + system prompt into the
     `messages` / `tools` / `add_generation_prompt` / `bos_token` context the templates expect
     (HF convention: `tools` is an array of `{"type":"function","function":{name,description,parameters}}`;
     reuse the Gemma 4 tool-JSON shaping already in `PromptTemplate.toolDeclarationBlock`).
   - Compile the `Template` once per model load and cache it (templates are `Hashable`,
     `Sendable`); parsing on every turn is wasteful.

4. **Change the fallback policy (detection stays, rendering replaces approximation).**
   - In `GenerationQueue` (or a new assembler in `ManifoldHardware`): **if a usable raw chat
     template is present, render it with Jinja**. Only fall back to the `PromptTemplate` enum
     approximation when there is **no** embedded template (templateless GGUFs, name-heuristic
     models). The enum cases stay for that path.
   - Keep `PromptTemplateDetector` exactly as-is — it still picks `thinkingMarkers` and the
     templateless fallback case, and is the detector for models with no embedded Jinja.
   - Wrap render in `do/catch` with `Log.*` (NOT `try?` — `SilentCatchAuditTest`). On render
     failure, log and fall back to the enum approximation rather than crashing
     (no `fatalError`/`assertionFailure` — there's a recovery path).

5. **Tests (≥2 fixtures comparing rendered output for templates that don't map cleanly).**
   - Add fixture `.jinja` files for **Qwen3.5** (maps to `.chatML`) and **Llama 3.1**
     (maps to `.llama3`) under `Tests/.../Fixtures/`, plus a golden expected-render string for
     each (with and without tools).
   - Unit test in `ManifoldHardwareTests`: render fixture → assert it equals golden →
     assert the golden **differs** from the enum `.format(...)` output for the same inputs
     (i.e. lock in that we fixed a real divergence; this doubles as the sabotage check).
   - Add a templateless case asserting the enum fallback still fires when `chatTemplate == nil`.
   - Add a render-failure case (malformed template) asserting graceful fallback + a logged warning.

6. **Docs + housekeeping.**
   - Update the `ManifoldHardware` row in `CLAUDE.md` (no longer "Zero deps" — now depends on
     swift-jinja) and the README/DocC notes describing prompt rendering.
   - If any DocC/snippet code uses Jinja APIs and is iOS-availability-bound, tag it
     ` ```swift,no-build ` (readme-snippets CI constraint).

7. **Gate before push:** `scripts/test.sh --profile local`, plus
   `swift package resolve && git diff Package.resolved` to confirm the pin set, plus a clean
   `swift build` (cache-cold) once to mirror the resolve-check / CI cold path.

### Out of scope for the impl PR
- Vision/image content parts in the template context (Qwen's `<|vision_start|>` branch) —
  the GGUF text path is text-only today; multimodal stays on the existing vision plumbing.
- Replacing the enum entirely — templateless models still need it.
