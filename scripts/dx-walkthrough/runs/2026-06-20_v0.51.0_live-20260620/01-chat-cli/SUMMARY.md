# DX Summary — 01-chat-cli (2026-06-20 v0.51.0 live-20260620)

**Runs completed:** 1 of 3 (single live agent run; run-2/run-3 not executed)
**Verdict:** **Working** — Ollama-backed REPL ships in ~5 min with public docs only.

## Acceptance criteria

| Criterion | Status |
|-----------|--------|
| `swift run` starts without crash | ✅ |
| Real streamed tokens (not stubs) | ✅ (`llama3.1:8b` via Ollama) |
| Two prompt/response cycles | ✅ |
| Ctrl-D clean exit | ✅ |
| `session.log` captured | ✅ |

## Top findings (by severity)

### Major
1. **No end-to-end REPL example** — `QUICKSTART-CLI.md` §3 is one-shot; the `readLine()` loop is only in §2 (GGUF). Consumers must compose two sections. *Fix: add §3b "Interactive REPL" with the combined snippet.*

### Minor
2. **Granular imports vs umbrella** — README pushes `import ManifoldKit`; CLI docs always show four module imports + three `register(with:)` calls even for single-backend use. *Fix: document whether umbrella suffices for CLI, or add a minimal Ollama-only Package.swift target.*
3. **REPL UX undocumented** — thinking→stderr is covered; status lines / prompt labels / clean `session.log` capture are not. *Fix: one paragraph on stderr conventions for headless apps.*

### Papercut
4. **Hardcoded `llama3.2` default** — doc warns to substitute but example still uses a tag many installs won't have. *Fix: use a placeholder comment or `ollama list` discovery note inline.*
5. **Heavy transitive resolve for cloud-only CLI** — expected given monolithic core, but surprising for "just Ollama" evaluators.

## Positive signals
- README → `QUICKSTART-CLI.md` discoverability is excellent.
- `@MainActor` isolation callout prevented Swift 6 compile failures.
- `GenerationStream.events` (not `AsyncSequence`) and thinking-token routing are well explained.
- Local-path `.package(name:path:)` guidance matches real worktree usage.

## Recommended follow-ups
- [ ] Add interactive REPL snippet to `docs/QUICKSTART-CLI.md` §3
- [ ] Clarify umbrella-import story for headless consumers
- [ ] Run run-2 (GGUF/`manifold-llama`) and run-3 (Foundation Models) for backend-variation comparison

## Run artifact
`runs/2026-06-20_v0.51.0_live-20260620/01-chat-cli/run-1/`