# ``ManifoldModelCatalog``

Model discovery, cataloguing, storage, and benchmarking — plus the top-level
configuration and error types the umbrella surfaces.

## Overview

`ManifoldModelCatalog` owns everything about *which* models exist and how they
are described, stored, and measured: `ModelInfo`, `ModelManifest`,
`ModelCatalog`, `ModelStorageService`, `DiagnosticsService`, `SettingsService`,
and `ModelBenchmarkRunner`. It also defines the package-level
``ManifoldConfiguration`` and ``ManifoldKitError`` that the `ManifoldKit`
umbrella threads through `quickStart`. It depends on the leaf capability,
networking, and security modules and sits below the Contract kernel.

## Topics

### Configuration & errors

- ``ManifoldConfiguration``
- ``ManifoldKitError``
