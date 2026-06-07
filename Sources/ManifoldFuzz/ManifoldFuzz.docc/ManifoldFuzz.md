# ``ManifoldFuzz``

The chat-fuzzing harness that stress-tests every ManifoldKit backend against
malformed prompts, mutated corpora, and adversarial streaming conditions.

## Overview

`ManifoldFuzz` drives a backend with seeded, mutated prompts and records every
generation as a structured ``RunRecord`` so findings are replayable, shrinkable,
and triageable long after the run. The harness is the engine behind
`scripts/fuzz.sh`; its on-disk `record.json` is the de-facto API every external
tool (`--replay`, `--shrink`, triage UIs, CI dashboards) decodes.

Because that on-disk shape is a public contract even though it crosses no Swift
API boundary, ``RunRecord`` carries an explicit ``RunRecord/schemaVersion`` and a
``RunRecord/validate(schemaVersion:)`` gate. See <doc:RunRecordSchema> for the
field-by-field reference and the three-step migration procedure.

## Topics

### Articles

- <doc:RunRecordSchema>

### Run records

- ``RunRecord``
- ``RunRecord/currentSchema``
- ``RunRecord/schemaVersion``
- ``RunRecord/validate(schemaVersion:)``
- ``RunRecord/SchemaError``
