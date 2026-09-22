#!/usr/bin/env python3
"""Dispatch and grade the registered application compatibility canary."""

from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tempfile
import time
import zipfile


ROOT = Path(__file__).resolve().parent.parent
REGISTRY_PATH = ROOT / "scripts/consumer-registry.py"
SHA_PATTERN = __import__("re").compile(r"[0-9a-f]{40}")
MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024
MAX_ARCHIVE_ENTRIES = 100_000
MAX_UNCOMPRESSED_BYTES = 8 * 1024 * 1024 * 1024
MAX_METADATA_BYTES = 1024 * 1024


class CanaryError(RuntimeError):
    pass


class PairMismatch(CanaryError):
    """Valid evidence for a different dispatch racing in the same workflow."""


def load_registry(path: Path) -> list[dict[str, str]]:
    spec = importlib.util.spec_from_file_location("consumer_registry", REGISTRY_PATH)
    if spec is None or spec.loader is None:
        raise CanaryError("could not load the consumer registry validator")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.load(path)


def gh(*arguments: str, output: Path | None = None) -> str:
    try:
        if output is None:
            completed = subprocess.run(
                ["gh", *arguments], check=False, capture_output=True, text=True,
                timeout=60,
            )
        else:
            with output.open("wb") as output_stream:
                completed = subprocess.run(
                    ["gh", *arguments], check=False, stdout=output_stream,
                    stderr=subprocess.PIPE, text=False, timeout=300,
                )
    except subprocess.TimeoutExpired as error:
        raise CanaryError(f"gh {' '.join(arguments[:3])} timed out") from error
    except OSError as error:
        raise CanaryError(f"could not execute gh: {error}") from error
    if completed.returncode != 0:
        stderr = completed.stderr.strip() if isinstance(completed.stderr, str) else completed.stderr.decode(errors="replace").strip()
        raise CanaryError(f"gh {' '.join(arguments[:3])} failed: {stderr or 'no diagnostic'}")
    return completed.stdout if isinstance(completed.stdout, str) else ""


def gh_json(*arguments: str) -> object:
    raw = gh(*arguments)
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise CanaryError("GitHub returned malformed JSON") from error


def require_sha(value: object, name: str) -> str:
    if not isinstance(value, str) or SHA_PATTERN.fullmatch(value) is None:
        raise CanaryError(f"{name} is not a full lowercase commit SHA")
    return value


def resolve_main_sha(repo: str) -> str:
    payload = gh_json("api", f"repos/ManifoldKit/{repo}/commits/main")
    if not isinstance(payload, dict):
        raise CanaryError(f"could not resolve ManifoldKit/{repo} main")
    return require_sha(payload.get("sha"), f"ManifoldKit/{repo} main")


def workflow_identity(repo: str, workflow: str) -> tuple[int, str]:
    payload = gh_json("api", f"repos/ManifoldKit/{repo}/actions/workflows/{workflow}")
    if not isinstance(payload, dict) or not isinstance(payload.get("id"), int):
        raise CanaryError(f"could not resolve {repo}/{workflow}")
    expected_path = f".github/workflows/{workflow}"
    if payload.get("path") != expected_path or payload.get("state") != "active":
        raise CanaryError(f"{repo}/{workflow} is not the active default-branch workflow")
    return payload["id"], expected_path


def repository_dispatch(repo: str, event_type: str, app_sha: str, core_sha: str) -> None:
    gh(
        "api", "--method", "POST", f"repos/ManifoldKit/{repo}/dispatches",
        "-f", f"event_type={event_type}",
        "-f", f"client_payload[app_ref]={app_sha}",
        "-f", f"client_payload[core_ref]={core_sha}",
    )


def list_run_ids(repo: str, workflow: str) -> set[int]:
    payload = gh_json(
        "api", "--method", "GET",
        f"repos/ManifoldKit/{repo}/actions/workflows/{workflow}/runs",
        "-f", "event=repository_dispatch", "-f", "branch=main", "-f", "per_page=100",
    )
    if not isinstance(payload, dict) or not isinstance(payload.get("workflow_runs"), list):
        raise CanaryError("GitHub returned an invalid workflow run list")
    ids = set()
    for run in payload["workflow_runs"]:
        if not isinstance(run, dict) or not isinstance(run.get("id"), int):
            raise CanaryError("GitHub returned an invalid workflow run identity")
        ids.add(run["id"])
    return ids


def parse_time(value: object) -> dt.datetime:
    if not isinstance(value, str):
        raise CanaryError("workflow run has no creation timestamp")
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise CanaryError("workflow run has a malformed creation timestamp") from error


def trusted_run(
    payload: object,
    *,
    repo: str,
    workflow_id: int,
    workflow_path: str,
    app_sha: str,
    dispatched_at: dt.datetime,
) -> bool:
    if not isinstance(payload, dict):
        raise CanaryError("GitHub returned an invalid workflow run")
    repository = payload.get("repository")
    head_repository = payload.get("head_repository")
    path = payload.get("path")
    if isinstance(path, str):
        path = path.split("@", 1)[0]
    return all((
        payload.get("workflow_id") == workflow_id,
        path == workflow_path,
        payload.get("event") == "repository_dispatch",
        payload.get("head_branch") == "main",
        payload.get("head_sha") == app_sha,
        isinstance(repository, dict) and repository.get("full_name") == f"ManifoldKit/{repo}",
        isinstance(head_repository, dict) and head_repository.get("full_name") == f"ManifoldKit/{repo}",
        parse_time(payload.get("created_at")) >= dispatched_at - dt.timedelta(seconds=5),
    ))


def validate_archive(path: Path, expected_app: str, expected_core: str) -> dict[str, object]:
    if path.stat().st_size > MAX_ARCHIVE_BYTES:
        raise CanaryError("canary artifact exceeds the compressed-size limit")
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            if len(entries) > MAX_ARCHIVE_ENTRIES:
                raise CanaryError("canary artifact has too many entries")
            total_size = 0
            metadata_entries = []
            for entry in entries:
                name = entry.filename
                pure = PurePosixPath(name)
                if "\\" in name or pure.is_absolute() or ".." in pure.parts:
                    raise CanaryError("canary artifact contains an unsafe path")
                total_size += entry.file_size
                if total_size > MAX_UNCOMPRESSED_BYTES:
                    raise CanaryError("canary artifact exceeds the uncompressed-size limit")
                if name == "canary-metadata.json":
                    metadata_entries.append(entry)
            if len(metadata_entries) != 1:
                raise CanaryError("canary artifact must contain exactly one root metadata file")
            metadata_entry = metadata_entries[0]
            if metadata_entry.file_size > MAX_METADATA_BYTES:
                raise CanaryError("canary metadata exceeds the size limit")
            metadata_bytes = archive.read(metadata_entry)
    except (OSError, zipfile.BadZipFile) as error:
        raise CanaryError("canary artifact is not a valid zip archive") from error
    try:
        metadata = json.loads(metadata_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CanaryError("canary metadata is malformed") from error
    if not isinstance(metadata, dict):
        raise CanaryError("canary metadata must be an object")
    schema_version = metadata.get("schemaVersion")
    if (
        isinstance(schema_version, bool)
        or not isinstance(schema_version, int)
        or schema_version != 1
    ):
        raise CanaryError("canary metadata has an unsupported schema version")
    exit_code = metadata.get("exitCode")
    if isinstance(exit_code, bool) or not isinstance(exit_code, int):
        raise CanaryError("canary metadata has an invalid exit code")
    app = metadata.get("app")
    core = metadata.get("core")
    if not isinstance(app, dict) or not isinstance(core, dict):
        raise CanaryError("canary metadata is missing resolved identities")
    app_sha = require_sha(app.get("commit"), "canary app commit")
    core_sha = require_sha(core.get("commit"), "canary core commit")
    if app_sha != expected_app or core_sha != expected_core:
        raise PairMismatch(
            f"canary artifact tested the wrong pair (app={app_sha}, core={core_sha})"
        )
    return metadata


def download_metadata(repo: str, run_id: int, prefix: str, app_sha: str, core_sha: str) -> dict[str, object]:
    payload = gh_json("api", f"repos/ManifoldKit/{repo}/actions/runs/{run_id}/artifacts")
    if not isinstance(payload, dict) or not isinstance(payload.get("artifacts"), list):
        raise CanaryError("GitHub returned an invalid artifact list")
    expected_name = f"{prefix}{run_id}"
    matches = [item for item in payload["artifacts"] if isinstance(item, dict) and item.get("name") == expected_name]
    if len(matches) != 1:
        raise CanaryError(f"run {run_id} must publish exactly one {expected_name} artifact")
    artifact = matches[0]
    if artifact.get("expired") is not False or not isinstance(artifact.get("id"), int):
        raise CanaryError(f"run {run_id} artifact is expired or malformed")
    size = artifact.get("size_in_bytes")
    if isinstance(size, bool) or not isinstance(size, int) or size < 1 or size > MAX_ARCHIVE_BYTES:
        raise CanaryError(f"run {run_id} artifact size is invalid")
    with tempfile.TemporaryDirectory(prefix="manifold-app-canary-") as directory:
        archive = Path(directory) / "evidence.zip"
        gh("api", f"repos/ManifoldKit/{repo}/actions/artifacts/{artifact['id']}/zip", output=archive)
        return validate_archive(archive, app_sha, core_sha)


def wait_for_result(
    *,
    repo: str,
    workflow: str,
    workflow_id: int,
    workflow_path: str,
    artifact_prefix: str,
    prior_ids: set[int],
    app_sha: str,
    core_sha: str,
    dispatched_at: dt.datetime,
    timeout_seconds: int,
    poll_seconds: int,
) -> str:
    deadline = time.monotonic() + timeout_seconds
    prior_cutoff = max(prior_ids, default=0)
    inspected: set[int] = set()
    while time.monotonic() <= deadline:
        fresh_ids = sorted(
            run_id for run_id in list_run_ids(repo, workflow)
            if run_id > prior_cutoff and run_id not in prior_ids
        )
        for run_id in fresh_ids:
            if run_id in inspected:
                continue
            run = gh_json("api", f"repos/ManifoldKit/{repo}/actions/runs/{run_id}")
            if not trusted_run(
                run, repo=repo, workflow_id=workflow_id, workflow_path=workflow_path,
                app_sha=app_sha, dispatched_at=dispatched_at,
            ):
                inspected.add(run_id)
                continue
            if run.get("status") != "completed":
                continue
            url = run.get("html_url")
            conclusion = run.get("conclusion")
            try:
                metadata = download_metadata(repo, run_id, artifact_prefix, app_sha, core_sha)
            except PairMismatch as error:
                inspected.add(run_id)
                print(
                    f"SKIP: fresh trusted run {run_id} belongs to another exact pair: {error}",
                    file=sys.stderr,
                )
                continue
            except CanaryError as error:
                raise CanaryError(
                    f"app canary run {run_id} ({conclusion}) at {url}: {error}"
                ) from error
            inspected.add(run_id)
            if conclusion != "success":
                raise CanaryError(f"app canary run {run_id} concluded {conclusion}: {url}")
            if metadata.get("status") != "passed" or metadata.get("exitCode") != 0:
                raise CanaryError(f"app canary run {run_id} published failed metadata")
            if not isinstance(url, str) or not url.startswith("https://github.com/ManifoldKit/"):
                raise CanaryError("app canary run has an invalid URL")
            return f"PASS: {repo} app canary {run_id} tested app={app_sha} core={core_sha}\n      {url}"
        if time.monotonic() <= deadline:
            time.sleep(poll_seconds)
    raise CanaryError(f"timed out after {timeout_seconds}s waiting for an exact-pair {repo} canary")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=ROOT / "scripts/consumer-registry.json")
    parser.add_argument("--core-ref", help="exact 40-character core commit (default: core main)")
    parser.add_argument("--timeout-seconds", type=int, default=6300)
    parser.add_argument("--poll-seconds", type=int, default=30)
    args = parser.parse_args()
    if args.timeout_seconds < 1 or args.poll_seconds < 0:
        parser.error("timeouts must be positive and poll seconds cannot be negative")
    try:
        rows = load_registry(args.registry)
        apps = [row for row in rows if row["kind"] == "app-canary"]
        if len(apps) != 1:
            raise CanaryError("exactly one app-canary registry entry is required")
        app = apps[0]
        core_sha = require_sha(args.core_ref, "core ref") if args.core_ref else resolve_main_sha("ManifoldKit")
        app_sha = resolve_main_sha(app["repo"])
        workflow_id, workflow_path = workflow_identity(app["repo"], app["workflow"])
        prior_ids = list_run_ids(app["repo"], app["workflow"])
        dispatched_at = dt.datetime.now(dt.timezone.utc)
        repository_dispatch(app["repo"], app["event_type"], app_sha, core_sha)
        print(wait_for_result(
            repo=app["repo"], workflow=app["workflow"], workflow_id=workflow_id,
            workflow_path=workflow_path, artifact_prefix=app["artifact_prefix"],
            prior_ids=prior_ids, app_sha=app_sha, core_sha=core_sha,
            dispatched_at=dispatched_at, timeout_seconds=args.timeout_seconds,
            poll_seconds=args.poll_seconds,
        ))
    except (CanaryError, OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
