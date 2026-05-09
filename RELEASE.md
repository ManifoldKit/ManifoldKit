# Release Artifacts

Every ManifoldKit release ships supply-chain integrity artifacts in
addition to the source archive. They are produced by
[`.github/workflows/release-provenance.yml`](./.github/workflows/release-provenance.yml)
and signed via [Sigstore](https://www.sigstore.dev/) using the GitHub
Actions OIDC token for this repository — there is no maintainer-held
signing key.

## Artifacts attached to every tag

| Artifact | What it is |
|----------|------------|
| `sbom.cdx.json` | CycloneDX 1.5 SBOM enumerating every Swift package dependency with its pinned git revision and upstream URL. Source: `Package.resolved`. |
| `dependency-tree.json` | `swift package show-dependencies --format json` snapshot taken on the tagged commit. |

Both artifacts have build-provenance attestations recorded in the
public transparency log
([Rekor](https://docs.sigstore.dev/logging/overview/)). The attestation
binds each artifact to:

- the exact commit SHA the tag points at,
- the workflow file that produced it (`release-provenance.yml`), and
- the GitHub repository (`roryford/ManifoldKit`).

## Verifying a release before pinning

Install the [GitHub CLI](https://cli.github.com/), then:

```bash
TAG=v0.12.2   # replace with the release you want to verify

gh release download "$TAG" \
    --pattern 'sbom.cdx.json' \
    --pattern 'dependency-tree.json' \
    --repo roryford/ManifoldKit

gh attestation verify sbom.cdx.json \
    --repo roryford/ManifoldKit \
    --predicate-type https://slsa.dev/provenance/v1

gh attestation verify dependency-tree.json \
    --repo roryford/ManifoldKit \
    --predicate-type https://slsa.dev/provenance/v1
```

A successful verification proves the file you downloaded is the file
the workflow produced, and that workflow ran on the tagged commit in
this repository.

If verification fails, treat the artifacts as untrusted and open a
security advisory via
[GitHub Security Advisories](https://github.com/roryford/ManifoldKit/security/advisories/new).

## What the attestations do *not* cover

- The source archive GitHub auto-generates from a tag (`zipball` /
  `tarball`) is not produced by this workflow and is not attested.
  Source-archive provenance and reproducible binary builds are tracked
  under [#714](https://github.com/roryford/ManifoldKit/issues/714) and
  [#728](https://github.com/roryford/ManifoldKit/issues/728).
- The attestation does not vouch for upstream dependencies themselves;
  it only asserts that the SBOM accurately enumerates what was pinned
  at tag time. Cross-checking the SBOM's `swift:git-revision` properties
  against upstream tags is left to the consumer.
- The `.xcframework` for `llama.swift` is consumed as a prebuilt
  binary blob from upstream; pinning it by SHA256 with a reproducibility
  audit is the scope of [#728](https://github.com/roryford/ManifoldKit/issues/728).

## Regenerating artifacts for an existing tag

If the SBOM generator has a bug fix and you need to refresh artifacts on
an already-published tag without cutting a new release, dispatch the
workflow manually:

```bash
gh workflow run release-provenance.yml --field tag=v0.12.2
```

`gh release upload --clobber` overwrites the previous artifacts and a
fresh attestation is appended to the transparency log.

## Dependency pinning posture

Every dependency is pinned in [`Package.resolved`](./Package.resolved)
by exact git revision. The `Verify Package.resolved is up to date` step
in [`.github/workflows/ci.yml`](./.github/workflows/ci.yml) refuses to
merge a PR that edits `Package.swift` without a corresponding
`Package.resolved` update.

The `ManifoldMacrosPlugin` target builds inside the SwiftPM sandbox
(`sandbox-exec` jail on macOS — no network, restricted filesystem
writes). A CI lint refuses to merge any change that adds `unsafeFlags`,
passes `--disable-sandbox` to `swift build`/`swift test` from a
workflow, or otherwise opts out of the jail. This is the only thing
standing between a compromised macro dependency and exfiltrating local
secrets at compile time.

## Generating an SBOM locally

```bash
./scripts/generate-sbom.sh --output sbom.cdx.json
```

The script reads `Package.resolved` directly, so it is offline and
deterministic — no network access, no SwiftPM resolution required.
