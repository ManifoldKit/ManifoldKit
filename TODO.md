# TODO

Cross-session notes. Not a tracker — real work lives in GitHub issues.

## Next up

- **Start Glass Box P0 after v0.38 ships.** Umbrella: [#1531](https://github.com/roryford/ManifoldKit/issues/1531).
  P0 = productionize the multicast event tap + public `ConversationEventRecorder`
  (`ManifoldRuntime`) + Swift-6 tests + "Observing a turn" DocC article.
  Keystone already spiked on branch `spike/conversation-event-tap` (c8d654fc) —
  reproduce properly, that branch is throwaway validation, not for merge.
  When P0 lands, update the `feedback_mock_backend_and_events_test_patterns` note
  (the single-consumer `runtime.events` workaround is what the tap retires).
