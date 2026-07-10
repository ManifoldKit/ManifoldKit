# Getting Started with ManifoldSkills

Wire filesystem-discovered skills into a chat session.

## 1) Discover skills on disk

``SkillLoader`` walks the default Claude-Code-compatible roots and returns the parsed `SkillDefinition` values. The default search paths are resolved lazily so iOS / sandboxed builds with no `$HOME` don't crash at module init.

> Warning: **macOS-only in v1.** On iOS, ``SkillLoader/discover()`` returns `[]`
> and logs a one-time warning. Skill discovery requires entitlement / app-group
> design that has not shipped yet.

```swift,no-build
import ManifoldSkills

let loader = SkillLoader()             // uses defaultClaudeCodePaths
let skills = loader.discover()
print("Found \(skills.count) skills")
```

To probe a specific directory (useful for tests or bundling skills inside an app), pass explicit roots:

```swift,no-build
import Foundation
import ManifoldSkills

let bundled = Bundle.main.url(forResource: "SampleSkills", withExtension: nil)!
let loader = SkillLoader(searchPaths: [bundled])
let skills = loader.discover()
```

## 2) Load skills into a registry

``SkillRegistry`` is an actor-isolated lookup table keyed by skill name and aliases. Later calls to ``SkillRegistry/load(_:)`` overwrite prior entries — last-wins, matching the path-precedence behaviour of ``SkillLoader/discover()``.

```swift,no-build
import ManifoldSkills

let registry = SkillRegistry()
await registry.load(SkillLoader().discover())

if let skill = await registry.skill(named: "explain") {
    print(skill.promptTemplate)
}
```

## 3) Wire a `SkillToolSource` into `ConversationRuntime`

``SkillToolSource`` is a ``ManifoldRuntime/SessionToolSource`` that advertises a single `invoke_skill` dispatcher to the model. Hand it to `ConversationRuntime` through the `sessionToolSources:` parameter — the runtime re-evaluates the advertised tool list every turn.

```swift,no-build
import ManifoldKit
import ManifoldRuntime
import ManifoldSkills

let registry = SkillRegistry()
await registry.load(SkillLoader().discover())
let skillSource = SkillToolSource(registry: registry)

let runtime = ConversationRuntime(
    messageStore: messageStore,
    inferenceService: inferenceService,
    sessionToolSources: [skillSource]
)
```

The model invokes a skill by calling `invoke_skill` with `{"skill_name": "...", "args": "..."}`. The source resolves the named skill, marks it as the active skill for the session, and returns the rendered prompt template as the tool result. On subsequent turns, ``SkillToolSource/allowedToolNames(for:)`` narrows the advertised tool list to the skill's `allowed-tools` (if any), strongly containing the model's surface area while the skill is in scope.

## 4) Bundling a `SKILL.md` with your app

Drop the `SKILL.md` into a resource directory and point ``SkillLoader`` at it. The directory layout is always `<root>/<skill-name>/SKILL.md`:

```
MyApp/Resources/SampleSkills/
└── explain/
    └── SKILL.md
```

A minimal `SKILL.md`:

```
---
name: explain
description: Explain a code snippet in plain English.
when-to-use: Use after pasting a function or class definition.
---

You are a senior engineer. Rewrite the snippet above as a clear, concise
explanation of what the code does and why.
```

See <doc:SkillFileFormat> for every recognised frontmatter key and <doc:ClaudeCodeInterop> for using existing Claude Code skill libraries unchanged.
