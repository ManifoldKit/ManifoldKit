# DX walkthrough briefs

Each brief frames a fresh ManifoldKit consumer's journey through a specific archetype. Briefs are read by an agent (or developer) that has not seen ManifoldKit's internals — they exercise the **public surface** only and produce a friction log.

## Phases

| # | Brief | Target | Surfaces | Cost | Cadence |
|---|-------|--------|----------|------|---------|
| 01 | `01-chat-cli.md` | macOS terminal | Chat happy path, streaming, backend choice | ~30 min | Per release |
| 02 | `02-swiftui-chat.md` | macOS SwiftUI | `ChatView`, persistence, `ChatViewModel`, SwiftData | ~60 min | Per release |
| 03 | `03-image-gen-app.md` | macOS SwiftUI | `MLXDiffusionBackend`, voice (`ManifoldVoice`), designer-to-app | ~90 min | Per release |
| 04 | `04-iphone-design-to-app.md` | **Physical iPhone** | All of 03 + iOS deployment, signing, on-device download, jetsam, share sheet, Photos | ~90–120 min | Pre-release / periodic |

Phases 01–03 are cheap-ish and can run on any Apple Silicon mac. **Phase 04 requires a physical iPhone, Apple Developer account / Personal Team, and a signing dance.** It is intentionally manual and not CI-gated.

## Shared design assets

`03-design-assets/` contains a real designer handoff (prose brief + runnable iPhone-framed flow viewer + JSX source for every screen). Phases 03 and 04 both consume it. The flow file is best opened in a browser:

```
open scripts/dx-walkthrough/briefs/03-design-assets/"LocalImage Flow.html"
```

## Privacy / public-repo conventions

- Briefs are committed and public; they must not contain personal paths, UDIDs, team IDs, or model paths specific to the maintainer's machine. They reference the MK repo via a placeholder path the runner fills in.
- Phase 04 creates a `RUN-CONFIG.md` in the run directory containing the developer's device UDID, team ID, and bundle ID. **`RUN-CONFIG.md` is gitignored** — never commit it.
- Run artefacts (`runs/*/*/run-*/`) are gitignored. Only the per-iteration `SUMMARY.md` / `ROOT_CAUSES.md` get committed.

## Adding a new brief

Pick an archetype that exercises a surface 01–04 don't already cover (e.g. RAG document Q&A, tool-calling agent, BYO-UI without `ChatView`). Match the existing brief shape:

- One-paragraph framing ("you are a developer evaluating MK for X")
- Required behaviour as a checkbox list
- Read allowlist + denylist (denylist always includes `Sources/Manifold*/**/*.swift` and `Tests/**`)
- Deliverables (`app/`, `FRICTION.md`, `session.log`, `NOTES.md`, screenshots)
- FRICTION.md template with archetype-specific categories
- "What we're trying to learn" — the specific public-surface question this archetype is built to answer
