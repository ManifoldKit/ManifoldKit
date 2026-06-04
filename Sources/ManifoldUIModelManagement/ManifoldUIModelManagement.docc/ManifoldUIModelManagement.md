# ``ManifoldUIModelManagement``

The model browser, downloader, and storage-management UI, plus cloud API endpoint editors.

## Overview

ManifoldUIModelManagement is the optional management surface that sits on top of ``ManifoldUI``. It provides the HuggingFace model browser, download progress, local-model storage management, and the API endpoint editors for cloud backends. A chat-only app does not need it; reach for it when your app lets users discover and install models at runtime.

This module also surfaces **device-aware model recommendations** — ranking surfaced models by how well they fit the current device for a chosen use case. The recommendations are designed around one principle: *honesty of presentation*. See <doc:DeviceAwareModelRecommendations>.

## Topics

### Articles

- <doc:DeviceAwareModelRecommendations>
