# ``BaseChatCore``

Models, protocols, and services for building on-device and cloud-connected chat applications.

## Overview

BaseChatCore is the foundation layer of BaseChatKit. It defines the protocol surface that backends and UI targets both depend on, and provides production-ready services for inference orchestration, context management, and persistence — with no dependency on MLX, llama.cpp, or any UI framework.

The two key entry points are ``BaseChatConfiguration`` (set once at app startup) and ``InferenceService`` (coordinates all model loading and generation). Everything else — persistence, context budgeting — is wired together by the service layer and exposed through SwiftData-backed models.

### Architecture

```
App
 ├── BaseChatConfiguration.shared   ← configure once at startup
 ├── InferenceService               ← orchestrates all backends
 │    ├── MLXBackend    (via BaseChatBackends)
 │    ├── LlamaBackend  (via BaseChatBackends)
 │    ├── FoundationBackend (via BaseChatBackends)
 │    └── CloudBackends (Claude, OpenAI, Ollama, …)
 └── SessionStore + MessageStore    ← SwiftData or custom storage
```

Backends are registered as factories so BaseChatCore stays free of any direct MLX, llama.cpp, or Foundation Models import. See <doc:GettingStarted> for the full wiring example.

## Topics

### Getting Started

- <doc:GettingStarted>

### Security

- <doc:SecurityModel>

### Configuration

- ``BaseChatConfiguration``

### Inference

- ``InferenceService``
- ``InferenceBackend``
- ``GenerationConfig``
- ``GenerationStream``
- ``BackendCapabilities``
- ``GenerationParameter``
- ``BackendActivityPhase``
- ``GenerationEvent``

### Models on Disk

- ``ModelInfo``
- ``ModelType``
- ``ModelStorageService``
- ``DownloadableModel``
- ``DownloadableModelGroup``
- ``DownloadState``
- ``DownloadStatus``

### Cloud & Remote

- ``APIEndpoint``
- ``APIProvider``
- ``RemoteBackendConfig``

### Chat Sessions & Persistence

- ``SessionStore``
- ``MessageStore``
- ``MessageStorePostWriteHook``
- ``SessionStorePostWriteHook``
- ``ChatSessionRecord``
- ``ChatMessageRecord``
- ``ChatPersistenceError``
- ``SwiftDataPersistenceProvider``
- ``ModelContainerFactory``

### Messages & Content

- ``ChatMessage``
- ``ChatSession``
- ``MessageRole``
- ``MessagePart``
- ``ChatError``

### Context

- ``ContextWindowManager``
- ``PromptAssembler``
- ``PromptSlot``
- ``TokenizerProvider``

### Prompt Formatting

- ``PromptTemplate``
- ``PromptTemplateDetector``

### Post-Generation Tasks

- ``PostGenerationTask``

### Settings

- ``SettingsService``

### Reliability & Diagnostics

- ``RetryPolicy``
- ``RepetitionDetector``
- ``BackendError``
- ``ModelCompatibilityResult``
- ``ModelTypeCompatibilityProvider``
- ``FrameworkCapabilityService``

### Schema

- ``BaseChatSchemaV3``
