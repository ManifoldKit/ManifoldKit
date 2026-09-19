# Foundation backend fixtures

The Foundation backend uses Apple's on-device language model via the
FoundationModels framework. Unlike file-based backends, there is no GGUF or
MLX model to load — the model is provided by the system (Apple Intelligence).

The slow `FoundationLocalBackendContractTests` explicitly load the system model
before generation. They assert a non-empty visible response and lifecycle
cleanup rather than exact token text: Apple can update the system model without
an app or package update, so a recorded answer would turn model evolution into
a false contract failure.

## Nightly tier

The Foundation contract participant skips generation scenarios unless
`RUN_SLOW_TESTS=1` is set in the environment and the OS is macOS 26 / iOS 26+.
Per-PR CI does not set this variable, so these live checks run only in the
nightly tier where Apple Intelligence is available.

The separate unloaded behavior remains a fast unit contract in
`FoundationBackendUnitTests.test_generate_beforeLoad_throwsNoModelLoaded`.
