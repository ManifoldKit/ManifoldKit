# `ManifoldSkills` now requires an explicit import

**Audience:** consumer
**Status:** living

## What changed

`ManifoldSkills` is no longer re-exported by the Core `ManifoldKit` umbrella.
The product remains available and is still Experimental; this change makes its
compatibility tier visible at the import boundary.

## Migration

Add the `ManifoldSkills` product to the target that uses skill discovery or
`invoke_skill`, then import it directly:

```swift,no-build:Package.swift manifest fragment, not standalone Swift
// Package.swift target dependencies
.product(name: "ManifoldSkills", package: "ManifoldKit")
```

```swift
import ManifoldKit
import ManifoldSkills
```

Code that only imports `ManifoldKit` and does not use skill APIs needs no
change.

## Why

The umbrella carries the Core compatibility promise. `ManifoldSkills` is a
Tier-3 Experimental product, so re-exporting it from `ManifoldKit` made the
weaker promise invisible to consumers. An explicit import preserves the
one-import path for the Core chat stack while making the experimental opt-in
deliberate.
