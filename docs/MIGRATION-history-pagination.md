# Migration: complete message history and keyset paging

**Audience:** consumer
**Status:** living

`MessageStore.fetchMessages(for:)` now consistently returns the complete
chronological transcript. SwiftData performs bounded keyset queries internally,
then materialises that complete result because exporters, branching, edits, and
whole-history compression require it.

Custom stores retain source compatibility through the default
`fetchMessageHistoryPage(for:cursor:limit:)` implementation. A custom store
whose legacy `fetchMessages(for:)` imposed a cap must update that method to
return complete history. Overriding paging alone does not change the full-history
method used by exports and compression. Implement the paging requirement for
efficient database traversal; if full-history fetching collects those pages,
override paging too, so it cannot recurse through the default implementation.
Pages use `(timestamp, UUID)` keys, so timestamp ties remain stable.

```swift
import Foundation
import ManifoldRuntime

func latestHistoryPage(
    in store: any MessageStore,
    for sessionID: UUID
) async throws -> MessageHistoryPage {
    try await store.fetchMessageHistoryPage(for: sessionID, cursor: nil, limit: 50)
}
```

Paging bounds each database fetch, not the final complete array. A page captures
a high-water key; inserts above it are excluded, while concurrent backdated
inserts and deletes are not a transaction snapshot.
