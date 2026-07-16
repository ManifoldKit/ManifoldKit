# Tool calling on local non-Gemma models (Llama / Qwen / Mistral)

**Audience:** consumer
**Status:** living

A single, end-to-end recipe for making a **local** instruct model call your tools.
This is the deep-dive companion to [QUICKSTART-TOOLS.md](QUICKSTART-TOOLS.md): that
guide covers `ToolDefinition`, `ToolRegistry`, and the dispatch loop that work
identically across every backend. This one covers the part that is *specific to
local prompt-template backends* (llama.cpp / MLX) and is the most common source of
"my model never calls the tool" bugs:

1. how tool definitions reach the model (you render them — the queue does **not**),
2. the exact `<tool_call>{JSON}</tool_call>` envelope the parser expects, and
3. the failure modes — including the silent drops.

> **Why "non-Gemma"?** Gemma-4 has a *native* tool block (`<|tool_call>` …
> `<|end_of_turn>`) that the template renders for you, and grammar-constrained
> decoding is **disabled** for the whole Gemma family because Gemma emits
> malformed/truncated output under structured JSON-object GBNF grammars (it opens
> the object then loops on whitespace until the token budget is exhausted). See
> "Gemma is excluded" below. Everything in this recipe is for the **other**
> families — Llama 3.x, Qwen, Mistral, Phi, ChatML fine-tunes — which share one
> JSON envelope and *do* support grammar constraint.

Types live in `ManifoldInference` (re-exported by `import ManifoldKit`). The
llama.cpp envelope parser lives in the companion package
[`manifold-llama`](https://github.com/ManifoldKit/manifold-llama).

---

## TL;DR

For a local non-Gemma model, a working turn is:

1. The queue renders the tool list into the system prompt for you (#1856), via
   `ToolSystemPromptBuilder.preferTools(for:)`, whenever the backend supports
   tool calling and the selected template doesn't render tools natively. You may
   still fold your own preamble in if you want a non-default style (see "Step 1").
2. You instruct the model to emit calls in the envelope
   `<tool_call>{"name":"…","arguments":{…}}</tool_call>`.
3. You pass the same `tools` to `enqueue(…)` so dispatch can match and run them.
   On a grammar-capable backend the queue *automatically* GBNF-constrains the
   envelope so the model can't drift off-format.
4. The stream surfaces `.toolCall`; the dispatch loop runs your executor and
   feeds the result back for another iteration.

```swift,no-build
// One turn, end to end (illustrative — symbols are real, wiring is yours).
import ManifoldKit

let tools: [ToolDefinition] = [weatherTool]   // your ToolDefinitions

// 1. The queue folds the tool preamble into the system prompt for you (#1856).
//    Just pass your plain app system prompt.
// 2 + 3. Pass tools to enqueue. Grammar auto-applies on grammar-capable backends.
let (_, stream) = try inferenceService.enqueue(
    messages: [.user("What's the weather in Paris?")],
    systemPrompt: "You are a helpful assistant.",
    tools: tools,
    toolChoice: .auto,
    maxToolIterations: 10
)

// 4. Consume events; the dispatch loop runs your registered executors.
for try await event in stream {
    switch event {
    case .token(let text): print(text, terminator: "")
    case .toolCall(let call): print("→ model called \(call.toolName)")
    default: break
    }
}
```

---

## Step 1 — Tools are rendered into the system prompt for you (#1856)

This used to be the #1 footgun: the queue passed `tools:` to the template but only
`.gemma4` consumed them, so on a Llama/Qwen/Mistral model the tool descriptions
never reached the model. **The queue now folds them in automatically.**

`GenerationQueue` calls `PromptTemplate.format(messages:systemPrompt:tools:)` for
every prompt-template backend. Only the `.gemma4` template consumes the `tools`
argument — it renders a native `<|tool>` block. Every other template (`.llama3`,
`.chatML`, `.mistral`, `.phi`, `.gemma`, `.alpaca`) discards `tools`. For those
templates the queue now prepends the `ToolSystemPromptBuilder.preferTools(for:)`
preamble to your system prompt before formatting — so the tool descriptions reach
the model without any host code. (`.gemma4` keeps its native block and is **not**
double-injected.)

This happens when **all** of the following hold:

- `backend.capabilities.supportsToolCalling == true`,
- `config.tools` is non-empty, and
- the selected template does **not** render tools natively
  (`PromptTemplate.rendersToolsNatively == false`).

`tools:` still matters beyond the preamble: dispatch uses it to match and run
calls, and it drives grammar derivation (Step 3).

If you want a non-default preamble style (`.strict` / `.minimal`) or your own
phrasing, you can still fold it in by hand — `ManifoldInference` ships the
canonical builder:

```swift,no-build
public static func preferTools(
    for definitions: [ToolDefinition],
    style: ToolSystemPromptBuilder.Style = .standard   // .standard | .strict | .minimal
) -> String
```

Fold it into your system prompt before enqueuing (only needed for a non-default
style — the `.standard` preamble is auto-injected):

```swift,no-build
let preamble = ToolSystemPromptBuilder.preferTools(for: tools, style: .strict)
let systemPrompt = preamble + "\n\n" + appSpecificSystemPrompt
```

`preferTools` returns an empty string when `tools` is empty, so it is safe to
concatenate unconditionally. It renders each tool as
`- <name>: <description> (arguments: a, b) (requires: a)` and (for
`.standard`/`.strict`) adds the imperative "When a tool can answer a question,
you MUST call the tool…", followed by the concrete emission format — a single
JSON object `{"name": …, "arguments": {…}}` using the listed argument names,
with an explicit prohibition on Python-style positional calls. That format
clause exists because templateless models (Phi-3.5, Mistral GGUF) reach the
model through this preamble alone and otherwise improvise an unparseable
`tool_call(value)` shape ([#2002](https://github.com/ManifoldKit/ManifoldKit/issues/2002)).
In ManifoldKit's own product testing the imperative preamble lifted
`llama3.1:8b` tool-recall from ~50% (no preamble) to 70–85%.

> **Is this auto-injected?** **Yes, as of [#1856](https://github.com/ManifoldKit/ManifoldKit/issues/1856).**
> The queue calls `ToolSystemPromptBuilder.preferTools(for:)` (`.standard` style)
> automatically for tool-capable backends whose template doesn't render tools
> natively, prepending it to your system prompt. You no longer need to fold the
> preamble in by hand for the default behaviour — supply only your app system
> prompt. Hand-folding is still supported and is the way to opt into `.strict` /
> `.minimal` styles or your own phrasing (it stacks on top of, not instead of,
> your app prompt). (Foundation Models, OpenAI, and Anthropic backends render
> tools natively on the wire and need none of this — auto-injection is specific
> to local prompt-template backends.)

The `.strict` style additionally tells the model to say "I don't have a tool for
that" rather than guessing — use it for agent workflows that branch on tool
output, where a hallucinated answer is costlier than a refusal.

---

## Step 2 — The envelope the parser expects (byte-for-byte)

A local model signals a tool call by emitting delimited text in its response.
`ToolCallTransform` (in `ManifoldContract`) scans the token stream for an
**open marker**, buffers the body until the matching **close marker**, then hands
the body to a dialect parser that returns a `ToolCall` — or `nil` to drop it.

For non-Gemma models the llama.cpp family (`manifold-llama`) registers exactly
**one** relevant marker pair — the **JSON envelope** (Qwen-style fine-tunes, and
the format every Llama/Mistral/ChatML instruct model is steered to with the
Step-1 preamble):

| Dialect | Open marker | Close marker | Body shape |
|---------|-------------|--------------|------------|
| **JSON** (Llama / Qwen / Mistral / ChatML) | `<tool_call>` | `</tool_call>` | `{"name":"…","arguments":{…}}` |
| Gemma-4 native *(excluded — see below)* | `<\|tool_call>` | `<\|end_of_turn>` | `call:name{key:<\|"\|>value<\|"\|>}` |

The exact bytes the parser accepts for a non-Gemma call:

```text
<tool_call>{"name": "get_weather", "arguments": {"city": "Paris"}}</tool_call>
```

Rules the parser actually enforces (verified against
`LlamaToolMarkers.parseJSONCall` and `ToolCallTransform`):

- The open tag is the literal `<tool_call>` and the close is the literal
  `</tool_call>`. No whitespace inside the tags.
- The body must be a JSON **object** with a non-empty `"name"` string. A missing
  or empty `name` → the call is dropped.
- `"arguments"` may be a JSON object (the normal case), a JSON **string**, or
  absent. When absent or unparseable it defaults to `{}` — the tool still
  dispatches, just with empty arguments.
- Body whitespace is trimmed before parsing, so pretty-printed JSON inside the
  tags is fine.
- Text outside the tags streams through as normal `.token` content; only the
  bytes between `<tool_call>` and `</tool_call>` are suppressed and parsed.

If two open tags compete in the same stream, the **earliest** open wins (ties
broken by registration order — Gemma-4 native is registered before JSON, so a
literal `<tool_call>` only ever matches the JSON dialect).

Your Step-1 preamble or app prompt should show the model this envelope literally.
A reliable phrasing:

> To call a tool, emit exactly:
> `<tool_call>{"name": "<tool_name>", "arguments": { … }}</tool_call>`
> and nothing else.

---

## Step 3 — Optional: GBNF-constrain the envelope (grammar-capable backends)

Steering the model with a prompt (Steps 1–2) works most of the time, but a model
can still drift off-format — emit a stray space in the tag, forget the closing
tag, or wrap the JSON in markdown. On a backend that advertises
`BackendCapabilities.supportsGrammarConstrainedSampling`, ManifoldKit closes that
gap automatically.

When you pass `tools:` to `enqueue(…)`, **and** the backend is grammar-capable,
**and** you did *not* supply your own `grammar:` string, the queue derives a GBNF
grammar from `config.tools` via `ToolGrammarBuilder` and applies it for you. The
grammar is a discriminated union over your tools — each branch pins `"name"` to
one tool's literal name and constrains `"arguments"` to *that tool's* JSON-Schema
parameters — so the model is forced to emit a well-formed, parseable envelope for
a real tool. There is no host code to write: it is on by default for
grammar-capable backends. An explicit `grammar:` you pass always wins (the queue
never overwrites a host-authored grammar).

```swift,no-build
// Nothing to do — this happens inside enqueue(…) when the backend supports it:
//   config.grammar == nil
//   && !config.tools.isEmpty
//   && backend.capabilities.supportsGrammarConstrainedSampling
//   → config.grammar = ToolGrammarBuilder().buildGrammar(for: config.tools)
```

Notes:

- `ToolGrammarBuilder` (issue
  [#1859](https://github.com/ManifoldKit/ManifoldKit/issues/1859)) landed on `main`.
  If you pin a released tag, confirm it is in your version before relying on it;
  the prompt-steering path (Steps 1–2) is the floor that works everywhere.
- Grammar makes the envelope *guaranteed parseable*, which lets you retire the
  brittle "scrape the text for JSON" fallback hosts used to write.
- **Gemma has grammar disabled** — which is exactly why this recipe targets
  non-Gemma models. See below.

---

## Step 4 — The dispatch loop feeds results back

Once the envelope parses, `ToolCallTransform` emits a `.toolCall(ToolCall)` event.
The queue's `GenerationToolDispatchLoop` looks the call up in your `ToolRegistry`,
runs the executor, appends the `ToolResult` to the transcript, and re-prompts the
model — up to `maxToolIterations` (default 10) — until the model produces a final
answer instead of another call. This loop is backend-agnostic and identical to the
cloud path; see [QUICKSTART-TOOLS.md](QUICKSTART-TOOLS.md) for registering
executors, approval gates, and streaming results.

You do **not** call the loop directly — `enqueue(messages:…:tools:)` (or, for
full chat orchestration, `ConversationRuntime.send`) is the entry point. Pass the
*same* `tools` array you rendered into the system prompt in Step 1.

---

## Failure modes (what "silently dropped" actually means)

These are the real, observable failure modes on `main`. Several produce **no
event at all**, which is why "my tool never fires" is hard to debug.

1. **Tools never rendered → model emits prose.** *Largely closed by
   [#1856](https://github.com/ManifoldKit/ManifoldKit/issues/1856).* This was the
   most common failure when the host had to fold the preamble in by hand and
   forgot. The queue now auto-injects `ToolSystemPromptBuilder.preferTools` for
   tool-capable backends whose template doesn't render tools natively, so passing
   `tools:` to `enqueue` is enough. It can still surface if the backend reports
   `supportsToolCalling == false` (see #5) or you pin a release predating #1856 —
   in that case fold the preamble in manually (Step 1).

2. **Malformed body → silent drop (no event).** If the body between
   `<tool_call>`…`</tool_call>` isn't valid JSON, or has a missing/empty
   `"name"`, `parseBody` returns `nil` and `ToolCallTransform` drops the call
   **emitting nothing** — no `.toolCall`, no error, no diagnostic. The host
   cannot distinguish "model emitted a broken call" from "model emitted no call."
   A surfaced diagnostic event is requested in
   [#1857](https://github.com/ManifoldKit/ManifoldKit/issues/1857) (**open**). Until
   then, GBNF constraint (Step 3) is the best defense — it prevents the malformed
   body in the first place.

3. **Unterminated block → discarded at finalize (no event).** If the stream ends
   (or is cancelled) while a `<tool_call>` block is open but its `</tool_call>`
   never arrived, `ToolCallTransform.finalize()` **discards the entire buffered
   body** — the partial call vanishes with no `.token` and no `.toolCall`. An
   opt-in to flush the partial body is requested in
   [#1858](https://github.com/ManifoldKit/ManifoldKit/issues/1858) (**open**).

4. **Runaway body → dropped at 256 KB.** A `<tool_call>` whose close tag never
   arrives buffers until it crosses a 256 KB cap, at which point the block is
   abandoned (a `Log.inference.warning` is emitted) and scanning resumes. This is
   a defensive guard against truncated/adversarial streams, not a normal path.

5. **`tools:` passed to a backend that can't call tools.** If the backend reports
   `capabilities.supportsToolCalling == false`, the queue logs a warning and the
   tools are ignored on the wire — calls never dispatch. Check
   `backend.capabilities.supportsToolCalling` before passing tools.

---

## Gemma is excluded — why

This recipe deliberately does not cover Gemma, for two reasons that both reduce to
"the local-model tool-calling story is different and more fragile for Gemma":

- **Native block, not the JSON envelope.** Gemma-4 emits
  `<|tool_call>…<|end_of_turn>` with a `call:name{key:<|"|>value<|"|>}` brace
  body, not `<tool_call>{JSON}</tool_call>`. The `.gemma4` template renders the
  tool block natively, so the Step-1 manual preamble does not apply the same way.
- **Grammar is disabled for the Gemma family.** `LlamaBackend` turns off
  grammar-constrained sampling for any model whose GGUF architecture starts with
  `gemma` (`gemma` / `gemma2` / `gemma3`), because Gemma emits
  malformed/truncated output under structured JSON-object GBNF grammars — it opens
  the object and then loops on whitespace until the token budget is exhausted,
  yielding zero parseable entities. The *identical* grammar produces valid JSON on
  Llama; the failure is Gemma-specific. So Step 3's reliability upgrade — the one
  that makes the envelope guaranteed-parseable — is unavailable on Gemma. Non-Gemma
  families keep grammar enabled and get the constrained envelope for free.

---

## See also

- [QUICKSTART-TOOLS.md](QUICKSTART-TOOLS.md) — `ToolDefinition`, `ToolRegistry`,
  `TypedToolExecutor`, approval gates, the backend-agnostic dispatch loop.
- [PROVIDER-BRIDGE.md](PROVIDER-BRIDGE.md) — tool calling on bridged cloud
  providers.
- [manifold-llama](https://github.com/ManifoldKit/manifold-llama) — the llama.cpp
  backend and the `LlamaToolMarkers` envelope parser.
