# ``ManifoldSkills``

Filesystem-discovered, prompt-template skills for ManifoldKit chat sessions.

## Overview

`ManifoldSkills` brings the Claude Code skill convention to ManifoldKit-powered apps. Discovery walks five Claude-Code-compatible roots — `~/.config/agents/skills`, `~/.agents/skills`, `~/.claude/skills`, `$PWD/.agents/skills`, and `$PWD/.claude/skills` — and loads any `SKILL.md` it finds with YAML frontmatter.

A ``SkillToolSource`` exposes a single `invoke_skill` dispatch tool to the model. The skill's `promptTemplate` is injected when invoked, and the optional `allowed-tools` frontmatter field narrows the model's tool surface while the skill is active.

**macOS-only in v1.** iOS skill discovery requires an entitlement/app-group design that hasn't shipped yet — on iOS ``SkillLoader/discover()`` returns `[]` and logs a one-time warning.

## Topics

### Essentials

- ``SkillDefinition``
- ``SkillLoader``
- ``SkillRegistry``
- ``SkillToolSource``

### Errors

- ``SkillDispatchError``

### Articles

- <doc:SkillsGettingStarted>
- <doc:SkillFileFormat>
- <doc:ClaudeCodeInterop>
