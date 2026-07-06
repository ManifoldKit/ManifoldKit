# ManifoldAppEval Report

> Deterministic-lane golden scenario results. Absence (`unavailable`) is reported explicitly — it is never scored as a failure.

**Verdict: FAIL**

## alpha-fixture

**Fixture verdict: FAIL**

| Checkpoint | Assertion | Result | Detail |
|---|---|---|---|
| greets back | expectedEvents | pass | (assertion=requiredContent) |
| greets back | requiredContent | pass | (assertion=requiredContent) |
| turn 1 | requiredContent | fail | Missing required content: goodbye (assertion=requiredContent) |

## beta-fixture

**Fixture verdict: PASS**

| Checkpoint | Assertion | Result | Detail |
|---|---|---|---|
| graph check | graph | unavailable | no scorer registered for custom key 'graph' |

