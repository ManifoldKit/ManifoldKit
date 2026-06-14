# The ModelPicker Sample

Drop in the bundled selector — or render your own over the headless ``ModelSelection``.

## Overview

``ModelPicker`` is a thin, public **sample** model selector. The real product is
the headless ``ModelSelection`` type in `ManifoldInference`, which vends the
sorted / scored / grouped model list as data and owns the synchronous load path.
Consumers are expected to render their own selector over that data; `ModelPicker`
is the default, not the only path. For the headless surface itself, see the
"Choosing and Loading Models (Headless)" guide (`docs/QUICKSTART-MODEL-SELECTION.md`).

## Using the bundled picker

`ModelPicker` reads selection state from a ``ModelRegistry`` (typically
`chatViewModel.modelRegistry`), so selecting in the picker is visible to any
sibling chat surface over the same registry. Pass an `onSelect` closure to react
to a tap — commonly to dismiss a presenting sheet:

```swift
import SwiftUI
import ManifoldKit
import ManifoldUIModelManagement

@MainActor
func makeFlatPicker(registry: ModelRegistry, dismiss: @escaping () -> Void) -> some View {
    ModelPicker(modelRegistry: registry, onSelect: dismiss)
}
```

## Grouped sections

Set `grouped: true` to render the Apple-Foundation-vs-downloaded sections that
``ModelSelection/groupModels(_:by:)`` produces. The flat single-list layout
(`grouped: false`) is the default and matches the bundled `ModelManagementSheet`:

```swift
import SwiftUI
import ManifoldKit
import ManifoldUIModelManagement

@MainActor
func makeGroupedPicker(registry: ModelRegistry) -> some View {
    ModelPicker(modelRegistry: registry, grouped: true, onSelect: {})
}
```

## Rendering your own

When the sample's chrome does not fit, render directly over ``ModelSelection``'s
data. The grouping and sorting helpers are public and used by `ModelPicker`
itself, so a custom view shares the same ordering:

```swift
import ManifoldKit

@MainActor
func sectionTitles(for models: [ModelInfo]) -> [String] {
    ModelSelection.groupModels(models, by: .capability).map { $0.group.title }
}
```

## Topics

### Sample view

- ``ModelPicker``
