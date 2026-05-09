# ``InferenceService``

## Topics

### State

- ``isModelLoaded``
- ``isGenerating``
- ``activeBackendName``
- ``activeModelName``
- ``capabilities``
- ``selectedPromptTemplate``
- ``lastTokenUsage``

### Loading Models

- ``loadModel(from:plan:)``
- ``loadCloudBackend(from:)``
- ``unloadModel()``
- ``resetConversation()``
- ``denyPolicy``

### Generation

- ``generate(messages:systemPrompt:temperature:topP:repeatPenalty:maxOutputTokens:)``
- ``stopGeneration()``

### Backend Registration

- ``registerBackendFactory(_:)``
- ``registerCloudBackendFactory(_:)``
- ``BackendFactory``
- ``CloudBackendFactory``

### Compatibility

- ``registeredBackendSnapshot()``

### Tokenization

- ``tokenizer``

### Deprecated

- ``generationDidFinish()``
