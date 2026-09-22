#!/usr/bin/env python3
"""Offline failure controls for the application compatibility adapter."""

import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("app_canary", ROOT / "scripts/app-canary-check.py")
assert SPEC is not None and SPEC.loader is not None
app_canary = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app_canary)

APP_SHA = "a" * 40
CORE_SHA = "c" * 40
DISPATCHED_AT = dt.datetime(2026, 9, 22, tzinfo=dt.timezone.utc)


def run_payload(**overrides):
    payload = {
        "id": 202,
        "workflow_id": 44,
        "path": ".github/workflows/core-canary.yml@refs/heads/main",
        "event": "repository_dispatch",
        "head_branch": "main",
        "head_sha": APP_SHA,
        "created_at": "2026-09-22T00:00:01Z",
        "status": "completed",
        "conclusion": "success",
        "html_url": "https://github.com/ManifoldKit/manifold-apps/actions/runs/202",
        "repository": {"full_name": "ManifoldKit/manifold-apps"},
        "head_repository": {"full_name": "ManifoldKit/manifold-apps"},
    }
    payload.update(overrides)
    return payload


def metadata(**overrides):
    payload = {
        "schemaVersion": 1,
        "status": "passed",
        "exitCode": 0,
        "app": {"commit": APP_SHA},
        "core": {"commit": CORE_SHA},
    }
    payload.update(overrides)
    return payload


class AppCanaryTests(unittest.TestCase):
    def make_archive(self, payload=None, *, members=None):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "artifact.zip"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "w") as archive:
                if members is None:
                    archive.writestr("canary-metadata.json", json.dumps(payload or metadata()))
                else:
                    for name, contents in members:
                        archive.writestr(name, contents)
        return path

    def wait(self, **overrides):
        arguments = {
            "repo": "manifold-apps",
            "workflow": "core-canary.yml",
            "workflow_id": 44,
            "workflow_path": ".github/workflows/core-canary.yml",
            "artifact_prefix": "manifold-apps-core-canary-",
            "prior_ids": {101},
            "app_sha": APP_SHA,
            "core_sha": CORE_SHA,
            "dispatched_at": DISPATCHED_AT,
            "timeout_seconds": 1,
            "poll_seconds": 0,
        }
        arguments.update(overrides)
        return app_canary.wait_for_result(**arguments)

    def test_success_requires_exact_trusted_run_and_metadata(self):
        with mock.patch.object(app_canary, "list_run_ids", return_value={101, 202}), \
             mock.patch.object(app_canary, "gh_json", return_value=run_payload()), \
             mock.patch.object(app_canary, "download_metadata", return_value=metadata()):
            result = self.wait()
        self.assertIn("app=" + APP_SHA, result)
        self.assertIn("core=" + CORE_SHA, result)

    def test_concurrent_wrong_pair_is_skipped_before_intended_pair(self):
        wrong_pair = app_canary.PairMismatch(
            "canary artifact tested the wrong pair (app=" + APP_SHA + ", core=" + ("d" * 40) + ")"
        )
        with mock.patch.object(app_canary, "list_run_ids", return_value={101, 202, 203}), \
             mock.patch.object(app_canary, "gh_json", side_effect=[run_payload(id=202), run_payload(id=203, html_url="https://github.com/ManifoldKit/manifold-apps/actions/runs/203")]), \
             mock.patch.object(app_canary, "download_metadata", side_effect=[wrong_pair, metadata()]):
            result = self.wait()
        self.assertIn("canary 203", result)

    def test_only_wrong_pair_times_out_without_accepting_it(self):
        wrong_pair = app_canary.PairMismatch(
            "canary artifact tested the wrong pair (app=" + APP_SHA + ", core=" + ("d" * 40) + ")"
        )
        with mock.patch.object(app_canary, "list_run_ids", return_value={101, 202}), \
             mock.patch.object(app_canary, "gh_json", return_value=run_payload()), \
             mock.patch.object(app_canary, "download_metadata", side_effect=wrong_pair), \
             mock.patch.object(app_canary.time, "monotonic", side_effect=[0, 0, 2, 2]), \
             mock.patch.object(app_canary.time, "sleep"):
            with self.assertRaisesRegex(app_canary.CanaryError, "timed out"):
                self.wait()

    def test_sabotage_missing_stale_and_pending_runs_timeout(self):
        scenarios = {
            "missing": ({101}, None),
            "stale": ({101, 202}, run_payload(created_at="2026-09-21T23:00:00Z")),
            "pending": ({101, 202}, run_payload(status="in_progress", conclusion=None)),
        }
        for name, (ids, payload) in scenarios.items():
            with self.subTest(name=name), \
                 mock.patch.object(app_canary, "list_run_ids", return_value=ids), \
                 mock.patch.object(app_canary, "gh_json", return_value=payload), \
                 mock.patch.object(app_canary.time, "monotonic", side_effect=[0, 0, 2, 2]), \
                 mock.patch.object(app_canary.time, "sleep"):
                with self.assertRaisesRegex(app_canary.CanaryError, "timed out"):
                    self.wait()

    def test_sabotage_failed_run_and_failed_metadata_never_pass(self):
        cases = (
            (run_payload(conclusion="failure"), metadata(status="failed", exitCode=1), "concluded failure"),
            (run_payload(), metadata(status="failed", exitCode=1), "published failed metadata"),
        )
        for run, evidence, message in cases:
            with self.subTest(message=message), \
                 mock.patch.object(app_canary, "list_run_ids", return_value={101, 202}), \
                 mock.patch.object(app_canary, "gh_json", return_value=run), \
                 mock.patch.object(app_canary, "download_metadata", return_value=evidence):
                with self.assertRaisesRegex(app_canary.CanaryError, message):
                    self.wait()

    def test_sabotage_untrusted_run_dimensions_never_reach_artifact(self):
        mutations = {
            "workflow": {"workflow_id": 45},
            "path": {"path": ".github/workflows/other.yml@refs/heads/main"},
            "event": {"event": "workflow_dispatch"},
            "branch": {"head_branch": "feature"},
            "app-head": {"head_sha": "b" * 40},
            "repository": {"repository": {"full_name": "attacker/manifold-apps"}},
        }
        for name, values in mutations.items():
            with self.subTest(name=name), \
                 mock.patch.object(app_canary, "list_run_ids", return_value={101, 202}), \
                 mock.patch.object(app_canary, "gh_json", return_value=run_payload(**values)), \
                 mock.patch.object(app_canary, "download_metadata") as download, \
                 mock.patch.object(app_canary.time, "monotonic", side_effect=[0, 0, 2, 2]), \
                 mock.patch.object(app_canary.time, "sleep"):
                with self.assertRaises(app_canary.CanaryError):
                    self.wait()
                download.assert_not_called()

    def test_archive_rejects_wrong_pair_status_schema_and_exit_type(self):
        cases = (
            (metadata(app={"commit": "b" * 40}), "wrong pair"),
            (metadata(core={"commit": "d" * 40}), "wrong pair"),
            (metadata(schemaVersion=2), "schema"),
            (metadata(schemaVersion=True), "schema"),
            (metadata(schemaVersion=1.0), "schema"),
            (metadata(schemaVersion="1"), "schema"),
            (metadata(exitCode=True), "exit code"),
        )
        for payload, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(app_canary.CanaryError, message):
                    app_canary.validate_archive(self.make_archive(payload), APP_SHA, CORE_SHA)

    def test_malformed_other_pair_is_not_skipped_as_concurrent_evidence(self):
        payload = metadata(
            schemaVersion=True,
            core={"commit": "d" * 40},
        )
        with self.assertRaisesRegex(app_canary.CanaryError, "schema") as error:
            app_canary.validate_archive(self.make_archive(payload), APP_SHA, CORE_SHA)
        self.assertNotIsInstance(error.exception, app_canary.PairMismatch)

    def test_archive_rejects_missing_duplicate_and_traversal_metadata(self):
        cases = (
            ([('other.json', '{}')], "exactly one"),
            ([('canary-metadata.json', '{}'), ('canary-metadata.json', '{}')], "exactly one"),
            ([('../canary-metadata.json', '{}')], "unsafe path"),
        )
        for members, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(app_canary.CanaryError, message):
                    app_canary.validate_archive(self.make_archive(members=members), APP_SHA, CORE_SHA)

    def test_archive_rejects_malformed_and_oversized_evidence(self):
        malformed = self.make_archive(members=[("canary-metadata.json", "{bad")])
        with self.assertRaisesRegex(app_canary.CanaryError, "metadata is malformed"):
            app_canary.validate_archive(malformed, APP_SHA, CORE_SHA)
        oversized_metadata = self.make_archive(members=[("canary-metadata.json", "x" * 20)])
        with mock.patch.object(app_canary, "MAX_METADATA_BYTES", 10):
            with self.assertRaisesRegex(app_canary.CanaryError, "metadata exceeds"):
                app_canary.validate_archive(oversized_metadata, APP_SHA, CORE_SHA)
        oversized_archive = self.make_archive(metadata())
        with mock.patch.object(app_canary, "MAX_ARCHIVE_BYTES", 1):
            with self.assertRaisesRegex(app_canary.CanaryError, "compressed-size"):
                app_canary.validate_archive(oversized_archive, APP_SHA, CORE_SHA)

    def test_missing_and_expired_artifacts_fail_with_run_diagnostics(self):
        cases = (
            ({"artifacts": []}, "exactly one"),
            ({"artifacts": [{
                "name": "manifold-apps-core-canary-202", "id": 9,
                "expired": True, "size_in_bytes": 100,
            }]}, "expired"),
        )
        for artifact_payload, message in cases:
            with self.subTest(message=message), \
                 mock.patch.object(app_canary, "list_run_ids", return_value={101, 202}), \
                 mock.patch.object(app_canary, "gh_json", side_effect=[run_payload(), artifact_payload]):
                with self.assertRaisesRegex(app_canary.CanaryError, r"run 202 .*https://github.com/.*" + message):
                    self.wait()

    def test_repository_dispatch_authorization_failure_is_terminal(self):
        with mock.patch.object(app_canary, "gh", side_effect=app_canary.CanaryError("denied POST")) as command:
            with self.assertRaisesRegex(app_canary.CanaryError, "denied POST"):
                app_canary.repository_dispatch("manifold-apps", "manifoldkit-apps-canary", APP_SHA, CORE_SHA)
        arguments = command.call_args.args
        self.assertIn("POST", arguments)
        self.assertIn("repos/ManifoldKit/manifold-apps/dispatches", arguments)
        self.assertIn("client_payload[app_ref]=" + APP_SHA, arguments)
        self.assertIn("client_payload[core_ref]=" + CORE_SHA, arguments)

    def test_entrypoint_does_not_downgrade_after_dispatch_is_denied(self):
        app_row = {
            "kind": "app-canary", "repo": "manifold-apps",
            "workflow": "core-canary.yml", "event_type": "manifoldkit-apps-canary",
            "artifact_prefix": "manifold-apps-core-canary-",
        }
        with mock.patch.object(sys, "argv", ["app-canary-check.py"]), \
             mock.patch.object(app_canary, "load_registry", return_value=[app_row]), \
             mock.patch.object(app_canary, "resolve_main_sha", side_effect=[CORE_SHA, APP_SHA]), \
             mock.patch.object(app_canary, "workflow_identity", return_value=(44, ".github/workflows/core-canary.yml")), \
             mock.patch.object(app_canary, "list_run_ids", return_value={101}), \
             mock.patch.object(app_canary, "repository_dispatch", side_effect=app_canary.CanaryError("denied POST")), \
             mock.patch.object(app_canary, "wait_for_result") as wait:
            self.assertEqual(app_canary.main(), 1)
        wait.assert_not_called()

    def test_auth_failure_is_terminal(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "gh"
            fake.write_text("#!/bin/sh\necho denied >&2\nexit 22\n")
            fake.chmod(0o755)
            with mock.patch.dict(os.environ, {"PATH": directory + ":" + os.environ["PATH"]}):
                with self.assertRaisesRegex(app_canary.CanaryError, "denied"):
                    app_canary.gh("api", "repos/ManifoldKit/manifold-apps")

    def test_cli_rejects_malformed_core_ref_before_dispatch(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/app-canary-check.py"),
             "--core-ref", "main", "--timeout-seconds", "1", "--poll-seconds", "0"],
            capture_output=True, text=True, check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("full lowercase commit SHA", result.stderr)


if __name__ == "__main__":
    unittest.main()
