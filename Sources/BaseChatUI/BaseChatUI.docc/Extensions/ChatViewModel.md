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
- ``unloadModel()``
