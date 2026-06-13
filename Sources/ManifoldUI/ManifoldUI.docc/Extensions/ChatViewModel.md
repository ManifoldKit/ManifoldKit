# ``ChatViewModel``

## Topics

### Session

- ``activeSession``
- ``switchToSession(_:)``

### Messages

- ``messages``
- ``inputText``
- ``sendMessage()``
- ``clearChat()``
- ``regenerateLastResponse()``
- ``editMessage(_:newContent:)``
- ``pinMessage(id:)``
- ``unpinMessage(id:)``

### Generation State

- ``isGenerating``
- ``isLoading``
- ``activityPhase``
- ``stopGeneration()``

### Model Selection

On-device backends surface choices through ``availableModels`` / ``selectedModel``: the Foundation Models backend (iOS/macOS 26+) ships in core, while the MLX and llama.cpp backends come from the `manifold-mlx` / `manifold-llama` companion packages (v0.48) once registered. Cloud and LAN backends (Ollama, OpenAI-compatible providers, Anthropic, and similar) surface saved endpoint records through ``availableEndpoints`` / ``selectedEndpoint``. Setting either property records the user's selection; call ``dispatchSelectedLoad()`` (or the explicit ``loadSelectedModel()`` / ``loadSelectedEndpoint()`` / ``loadCloudEndpoint(_:)`` entry points) to actually load it.

- ``selectedModel``
- ``selectedEndpoint``
- ``availableModels``
- ``availableEndpoints``

### Generation Settings

- ``systemPrompt``
- ``pinnedMessageIDs``

### Errors

- ``activeError``
- ``errorMessage``
- ``backgroundTaskError``

### Extensibility

- ``postGenerationTasks``
- ``onFirstMessage``
- ``onFirstLaunch``
- ``foundationModelProvider``

### Initialization & Setup

- ``configure(runtime:)``
- ``configure(persistence:)``
- ``refreshModels()``
- ``loadSelectedModel()``
- ``loadSelectedEndpoint()``
- ``unloadModel()``
