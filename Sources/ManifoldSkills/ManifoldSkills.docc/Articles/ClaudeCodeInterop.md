# Claude Code Interop

Drop existing Claude Code skill libraries into a ManifoldKit-powered app unchanged.

## The drop-in path

``SkillLoader``'s default search paths match the Claude Code convention. An existing `~/.claude/skills/<name>/SKILL.md` is discovered on first launch with no setup beyond constructing a default loader:

```swift,no-build
import ManifoldSkills

let loader = SkillLoader()
let skills = loader.discover()    // includes anything in ~/.claude/skills
```

## Path priority order

``SkillLoader`` walks these roots in order. **Last wins** on duplicate skill names so a project-local skill overrides a user-wide one — mirroring Claude Code's "project beats user" behaviour.

| # | Path | Scope |
|---|---|---|
| 1 | `~/.config/agents/skills` | XDG-style user-wide library |
| 2 | `~/.agents/skills` | Legacy user-wide library |
| 3 | `~/.claude/skills` | Claude Code user-wide library |
| 4 | `$PWD/.agents/skills` | Project-local override |
| 5 | `$PWD/.claude/skills` | Project-local Claude Code override (highest precedence) |

Within a single root, two `SKILL.md` files declaring the same `name:` are not collapsed — the first occurrence wins and the rest log a warning. Across roots, the later root wins silently (the per-root scan deduplicates by name; the cross-root merge in ``SkillLoader/discover()`` overwrites by name as it walks each root in order).

## What's reused, what isn't

| Claude Code construct | ManifoldKit behaviour |
|---|---|
| `SKILL.md` layout + frontmatter | Reused verbatim. See <doc:SkillFileFormat>. |
| `name`, `description`, `when-to-use`, `argument-hint`, `aliases` | Reused. |
| `allowed-tools` | Reused with the same gating semantics (intersect the executor's tool list while the skill is active). |
| `model:` hint | Parsed but **ignored** in v1 — ManifoldKit picks the active model from session settings, not the skill. |
| Per-skill tool definitions surfaced individually to the model | **Not yet.** v1 ships a single `invoke_skill` dispatcher (capped at 6 skills) to keep the per-turn tool budget bounded. Mirroring Claude Code's per-skill tool pattern is deferred to v2 once prompt-caching ergonomics catch up. |

## Sharing skills between Claude Code and a ManifoldKit app

The simplest workflow:

1. Author skills once in `~/.claude/skills/<name>/SKILL.md`.
2. Use them from Claude Code as usual.
3. Launch a ManifoldKit-powered app on the same machine; the skills appear automatically.

No symlink, no env var, no app-specific path is required on macOS.

## iOS

iOS skill discovery requires an entitlement/app-group design that hasn't shipped yet. ``SkillLoader/discover()`` returns `[]` on iOS and logs a one-time warning so app authors notice. The module compiles on iOS as a no-op so trait-gated dependencies still link.
