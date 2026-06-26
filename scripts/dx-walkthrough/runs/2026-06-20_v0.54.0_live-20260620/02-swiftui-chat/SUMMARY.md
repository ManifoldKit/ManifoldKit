# DX Summary — 02-swiftui-chat (2026-06-20 v0.54.0 live-20260620)

**Runs completed:** 1 of 3 (single live agent run)
**Verdict:** **Working** — multi-session SwiftUI app with Ollama generation and persistence verified.

## Acceptance criteria

| Criterion | Status |
|-----------|--------|
| Compiles cleanly | ✅ SwiftPM executable, macOS 26 |
| Launches SwiftUI window | ✅ `DXSwiftUIChat` process + "Chat" window |
| Chat interface visible | ✅ Sidebar + `ChatView` composer |
| Generation end-to-end | ✅ `[dx] generation OK: Hello, how are you?` via `sendMessage` |
| Sessions persist across relaunch | ✅ `ZCHATSESSION`=1, `ZCHATMESSAGE`=2 after kill + relaunch |

## Top findings (by severity)

### Major
1. **No SwiftPM SwiftUI app recipe** — `MinimalExample` is Xcode-only (`xcodegen`); multi-session guide shows `App` code but not executable `Package.swift`. *Fix: add a "SwiftPM macOS app" box to `SWIFTUI-MULTI-SESSION.md` or `QUICKSTART.md`.*
2. **Multi-session §2 doesn't include model load** — `quickStart()` alone leaves composer inert; Foundation/Ollama seed steps live in separate `QUICKSTART.md` sections. *Fix: cross-link or inline a "make it generate" block in §2.*
3. **Ollama seed `isEmpty` guard breaks relaunch** — persisted endpoint skips seed block; model not re-loaded. *Fix: document "always call `loadSelectedEndpoint()` on launch when using pre-seeded cloud endpoints".*

### Minor
4. **`sendMessage` for scripted verification lives in `AGENTS.md`** — not surfaced in SwiftUI quickstart path; useful for headless DX proof when UI automation fails.

### Papercut
5. **SwiftData store path undocumented** — persistence works but store location is trial-and-error under `~/Library/Application Support/<bundleIdentifier>/`.

## Positive signals
- `SWIFTUI-MULTI-SESSION.md` §2 is an excellent multi-session default (`quickStart` + `SessionManagerViewModel` + `onChange` wiring).
- `ManifoldUIModelManagement` correctly documented as optional for pre-seeded Ollama.
- Umbrella `import ManifoldKit` covers the full SwiftUI stack without import sprawl.

## Comparison to scenario 01 (chat-cli)
| Dimension | 01 CLI | 02 SwiftUI |
|-----------|--------|------------|
| Time to first token | ~5 min | ~15 min (incl. model-load debugging) |
| Doc fragmentation | 2 sections to stitch | 3 sections to stitch |
| Drop-in completeness | §3b now fixes REPL gap | §2 still missing model-load |
| Persistence | N/A | Works once load bug patched |

## Recommended follow-ups
- [ ] SwiftPM executable recipe for macOS SwiftUI in `SWIFTUI-MULTI-SESSION.md`
- [ ] "Reload cloud endpoint on every launch" callout in Ollama seed snippet
- [ ] Optional §2 variant with Ollama pre-seed + `loadSelectedEndpoint` inlined

## Run artifact
`runs/2026-06-20_v0.54.0_live-20260620/02-swiftui-chat/run-1/`