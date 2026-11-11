# ManifoldAppEval Report

> Deterministic-lane golden scenario results. Missing required evidence is INDETERMINATE; informational measurements do not drive the gate.

**Verdict: FAIL**

## alpha-fixture

**Fixture verdict: FAIL**

| Checkpoint | Assertion | Result | Detail |
|---|---|---|---|
| greets back | expectedEvents | pass | (assertion=requiredContent) |
| greets back | requiredContent | pass | (assertion=requiredContent) |
| turn 1 | requiredContent | fail | Missing required content: goodbye (assertion=requiredContent) |

## beta-fixture

**Fixture verdict: INDETERMINATE**

| Checkpoint | Assertion | Result | Detail |
|---|---|---|---|
| graph check | graph | unavailable | no scorer registered for custom key 'graph' |
| empty checkpoint | _(none)_ | — | no assertions declared |

