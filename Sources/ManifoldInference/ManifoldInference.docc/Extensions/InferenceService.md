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
- ``loadEndpointBackend(from:)``
- ``unloadModel()``
- ``resetConversation()``
- ``denyPolicy``

### Generation

- ``generate(messages:systemPrompt:temperature:topP:repeatPenalty:maxOutputTokens:)``
- ``stopGeneration()``

### Backend Registration

- ``registerBackendFactory(_:)``
- ``registerEndpointBackendFactory(_:)``
- ``BackendFactory``
- ``EndpointBackendFactory``

### Compatibility

- ``registeredBackendSnapshot()``

### Tokenization

- ``tokenizer``

### Deprecated

- ``generationDidFinish()``
