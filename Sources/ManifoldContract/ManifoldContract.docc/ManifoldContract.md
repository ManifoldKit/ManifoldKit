# ``ManifoldContract``

The Contract kernel — the backend protocols and value/stream types every
ManifoldKit engine and consumer is written against.

## Overview

`ManifoldContract` defines the narrow seam between inference engines and the
rest of ManifoldKit: the backend protocols (``InferenceBackend``,
`EmbeddingBackend`), the generation value types (`GenerationConfig`,
`GenerationEvent`, `Message`), and the tool-calling vocabulary
(`ToolDefinition`, `ToolCall`, `ToolResult`) plus the streaming transforms that
connect them. It depends only on the leaf capability and catalog modules and
must never depend on the inference engine — every backend family compiles
against this kernel alone.

## Topics

### Backend protocols

- ``InferenceBackend``
