# Security Policy

The canonical security policy for ManifoldKit lives at the repository root:

- [`SECURITY.md`](../SECURITY.md) — supported versions, supported build modes,
  reporting a vulnerability, cryptography at rest, and pending mitigations.
- [`docs/THREAT_MODEL.md`](../docs/THREAT_MODEL.md) — the engineering-honest threat
  model: assets, trust boundaries, mitigation enforcement table, and known
  non-mitigations.

This file remains as a redirect because GitHub looks for `SECURITY.md` in `.github/`,
the repository root, and `docs/` — keeping a copy here ensures the **Security** tab
surface in the GitHub UI continues to render after the canonical doc moved to the
root.

## Reporting

Use [GitHub Security Advisories](https://github.com/ManifoldKit/ManifoldKit/security/advisories/new)
for private disclosure. **Do not** open public issues for security-impacting bugs.

Full policy: [`SECURITY.md` § Reporting a vulnerability](../SECURITY.md#reporting-a-vulnerability).
