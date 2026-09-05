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

Message-scope session search no longer exposes
`SessionManagerViewModel.messageSearchSessionResolveCap`. The former 10,000-session
resolution cap could hide matches in older sessions; results now resolve each distinct
matching session directly. Remove uses of that constant; there is no replacement API.

Message search now scans fixed-size candidate pages until the requested number of
all-term matches is found or the candidates are exhausted. Results are ordered by
descending timestamp, then UUID. Cancellation is observed between pages. The page
bound limits fetched rows, not total scan time or the requested result array;
concurrent inserts, edits and deletes are not a transaction snapshot.
