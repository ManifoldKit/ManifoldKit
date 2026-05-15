# Fixture redaction policy

Fixtures under `Tests/Fixtures/` are committed to a public repository. Every
captured request/response must be scrubbed of provider credentials, customer
identifiers, and per-host metadata before it lands in git.

`FixtureRedactionAuditTest` walks `Tests/Fixtures/backends/` and the existing
`Tests/Fixtures/ollama/` tree on every test run and fails the build if any of
the patterns below appear. The same patterns drive the `jq` filter inside
`scripts/record-fixture.sh`.

## Patterns that MUST be redacted

| Source | Pattern | Replace with |
|--------|---------|--------------|
| OpenAI / generic API key | `sk-[A-Za-z0-9]{20,}` | `sk-REDACTED` |
| Anthropic API key | `sk-ant-[A-Za-z0-9_-]+` | `sk-ant-REDACTED` |
| OpenAI org id | `org-[A-Za-z0-9]+` | `org-REDACTED` |
| HTTP Bearer | `Bearer [A-Za-z0-9._-]+` | `Bearer REDACTED` |
| Account UUIDs in `account_*` JSON keys | RFC4122 in any field named `account_id`, `account_uuid`, `customer_id` | `00000000-0000-0000-0000-000000000000` |
| Email addresses | `[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}` | `user@example.com` |
| IPv4 addresses | `\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}` (excluding `127.0.0.1` and `0.0.0.0`) | `192.0.2.1` (RFC 5737 TEST-NET) |

## How to record a fresh fixture

1. Set env vars for the live provider (`OPENAI_API_KEY`, etc.).
2. Run `scripts/record-fixture.sh <provider> <scenario> <output-path>` —
   the script pipes the SSE/NDJSON stream through `jq` with the redaction
   filter applied per-line.
3. Inspect the resulting file. Manually scrub anything the regexes missed
   (free-form `content` strings can leak names if the prompt contained them).
4. Commit. CI re-runs `FixtureRedactionAuditTest` on every push, so a
   secret that slips past step 3 fails the build instead of merging.

## Allowlist policy

`FixtureRedactionAuditTest` carries a capped fingerprint allowlist for the
rare case where a pattern matches a fixture deliberately (e.g. testing that
the OpenAI error path for an invalid `org-` id is preserved verbatim). Each
allowlist entry pairs with an inline `// CODEOWNER: security` comment in
the test file. Adding to the allowlist requires reviewer sign-off and is
expected to stay near-empty.

## Non-credential PII

Customer-supplied prompt text is the largest residual leak risk; the regex
sweep cannot detect arbitrary names, addresses, or phone numbers embedded in
prompt strings. Authors of new fixtures are responsible for either using
synthetic prompts (`"What is the capital of France?"`) or hand-scrubbing
identifying details. The audit catches the structured cases.
