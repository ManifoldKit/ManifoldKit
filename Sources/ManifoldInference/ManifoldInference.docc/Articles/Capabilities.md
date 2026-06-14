# Model Capability Flags

Resolve a model's code, multilingual, and reasoning capabilities from
``ModelInfo`` instead of re-deriving them in your app.

## Overview

Every host app that builds a model picker eventually re-implements the same
question: *can this model write code? Is it multilingual? Does it reason?*
ManifoldKit answers those questions on ``ModelInfo`` — honestly, and only where
it can actually tell.

Three resolved flags are exposed:

- ``ModelInfo/supportsCode`` — the checkpoint advertises code-generation
  specialisation.
- ``ModelInfo/supportsMultilingual`` — the checkpoint advertises two or more
  natural languages.
- ``ModelInfo/supportsReasoning`` — the model exposes extended-thinking /
  reasoning output.

Each resolves `curated ?? detected ?? false`: an explicit curation override
wins; otherwise an auto-detected value; otherwise an honest `false`.

## Where each flag is sourced

**Code / multilingual** are auto-detected by `ModelCapabilityProbe`, which reads
a Hugging Face model directory's `config.json` plus `README.md` front-matter
(`pipeline_tag`, `tags`, `language`). MLX directory models carry a sibling
`config.json`, so discovery populates these automatically.

**Reasoning** for *cloud* models is sourced from the vendored
`CloudModelManifestTable` (which already tracks which OpenAI / Anthropic
families expose extended thinking). Call
``ModelInfo/detectCloudReasoning(modelName:producer:)`` with the configured
model name.

## Two honesty limits — read these before you branch on a flag

**1. GGUF code/multilingual ship honest-`false` unless curated.** A GGUF model
is a single file with no sibling `config.json`, so `ModelCapabilityProbe` cannot
run — it throws `configNotFound`, which ManifoldKit treats as *no detection*
(the detected layer stays `nil`), never a fatal error. The resolved flag is
therefore `false` for an uncurated GGUF coder. To assert the capability, set a
curation override.

**2. `supportsReasoning` is honest-`false` for every local model unless
curated.** There is no reliable local-model reasoning signal, so GGUF / MLX /
Foundation models resolve `supportsReasoning == false` by default.

> Important: This is a routing footgun. A snippet like
> `if model.supportsReasoning { useReasoningPrompt() }` silently takes the
> `false` branch for every uncurated local model — including ones that really
> do reason. If your router depends on reasoning, curate the flag explicitly
> rather than trusting the default.

## Curating a capability

Use ``ModelInfo/applyCuratedCapabilities(_:)`` to override detection. Only
non-`nil` fields override; `nil` leaves the detected layer intact, so a re-probe
can still refresh detection without clobbering your curation.

```swift
import ManifoldKit

/// Marks a known GGUF coder model as code-capable even though its single-file
/// format carries no `config.json` for auto-detection, and routes on the
/// resolved flags.
func curateAndRoute(_ model: ModelInfo) -> ModelInfo {
    var curated = model
    curated.applyCuratedCapabilities(
        CuratedModelCapabilities(supportsCode: true)
    )

    // Resolved accessors fold curated-over-detected-over-false.
    if curated.supportsCode {
        // route to a code-oriented system prompt
    }
    if curated.supportsReasoning {
        // honest-false for uncurated local models — see the footgun note above
    }
    return curated
}
```

## Topics

### Resolved flags

- ``ModelInfo/supportsCode``
- ``ModelInfo/supportsMultilingual``
- ``ModelInfo/supportsReasoning``

### Curation override

- ``CuratedModelCapabilities``
- ``ModelInfo/applyCuratedCapabilities(_:)``

### Detection

- ``ModelInfo/detectCapabilities(fromModelDirectory:)``
- ``ModelInfo/detectCloudReasoning(modelName:producer:)``
