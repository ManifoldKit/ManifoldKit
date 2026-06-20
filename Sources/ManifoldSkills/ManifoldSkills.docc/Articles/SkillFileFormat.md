# SKILL.md File Format

The on-disk shape ``SkillLoader`` parses.

## Layout

A skill is a directory containing exactly one `SKILL.md` file:

```
<search-root>/<skill-name>/SKILL.md
```

The Markdown body is the skill's `promptTemplate` — verbatim, with no further processing. The YAML frontmatter at the top of the file carries metadata.

## Frontmatter

Frontmatter is the YAML block delimited by `---` on its own line at the top of the file. A `SKILL.md` without frontmatter is **rejected** and logged as malformed — frontmatter is required for `name` and `description`.

```
---
name: explain
description: Explain a code snippet in plain English.
aliases:
  - explainer
  - eli5
allowed-tools:
  - read_file
when-to-use: Use after pasting a function or class definition.
argument-hint: A short focus question, optional.
references:
  - reference.md
  - examples/walkthrough.md
model: sonnet
---

<prompt template body — the skill's instructions to the model>
```

### Required keys

| Key | Type | Behaviour when missing/malformed |
|---|---|---|
| `name` | string | Skill is **skipped** and a warning is logged. The name is the canonical identifier in ``SkillRegistry`` and the value the model passes as `skill_name`. |
| `description` | string | Skill is **skipped** and a warning is logged. Surfaces as the per-skill bullet in the `invoke_skill` tool description. |

### Optional keys

| Key | Type | Behaviour when missing |
|---|---|---|
| `aliases` | list of strings (or single string) | Alternate identifiers that resolve to this skill in ``SkillRegistry/skill(named:)``. Defaults to empty. |
| `allowed-tools` | list of strings | When present, intersects the executor's advertised tool list while the skill is active (strong containment, mirrors Claude Code's `allowed-tools` gating). **Absent** means "no restriction" — equivalent to ``Skill/allowedTools`` being `nil`. **Present with empty list** means "deny all" (prompt-only skill); the skill's prompt template runs but no tools are exposed. |
| `when-to-use` | string | Routing hint surfaced in the `invoke_skill` **tool description** (not the parameter description, which OpenAI truncates aggressively). Defaults to `nil`. |
| `argument-hint` | string | Surfaced as the `args` parameter description. Defaults to a generic message. |
| `references` | list of strings (or single string) | **L3 progressive disclosure.** Relative paths (under the skill's own directory) to companion files the body can point the model at. They are **not** read at discovery or inlined on dispatch — `invoke_skill` advertises only their names, and the host reads one on demand via ``Skill/resolveReference(_:)``. Resolution is dir-confined: `..`, absolute paths, and undeclared files throw `SkillReferenceError`. Defaults to empty. |
| `model` | string | Skill-author hint for which model class to use. **Parsed but ignored in v1.** |

### Behaviour when the file is unreadable

- File I/O error → the skill is skipped and a warning logged with the path and error.
- Malformed frontmatter → the skill is skipped and a warning logged.
- Two `SKILL.md` files within the **same** search-path root with the same `name:` → the first occurrence wins; subsequent duplicates are skipped with a warning.
- A `name:` collision **across** search-path roots → last-wins, in priority order. See <doc:ClaudeCodeInterop> for the priority table.

## Duplicate-key precedence inside frontmatter

The frontmatter parser is line-oriented; the **last** assignment to a given key in a single file wins. Skill authors should avoid repeating keys — the implicit choice is deliberately not documented as stable.
