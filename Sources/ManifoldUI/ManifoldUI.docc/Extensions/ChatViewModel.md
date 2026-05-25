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

Local backends (MLX, Llama, Foundation) surface choices through ``availableModels`` / ``selectedModel``. Cloud and LAN backends (Ollama, OpenAI-compatible providers, Anthropic, and similar) surface saved endpoint records through ``availableEndpoints`` / ``selectedEndpoint``. Setting either property records the user's selection; call ``dispatchSelectedLoad()`` (or the explicit ``loadSelectedModel()`` / ``loadSelectedEndpoint()`` / ``loadCloudEndpoint(_:)`` entry points) to actually load it.

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
