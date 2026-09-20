#!/usr/bin/env python3
"""Release plumbing regression tests. Network calls are recorded by fixture CLIs."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("registry", ROOT / "scripts/consumer-registry.py")
registry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(registry)

FAKE_GH = r'''#!/usr/bin/env python3
import datetime, json, os, pathlib, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ['FIXTURE'])
with (root / 'calls').open('a') as f: f.write(json.dumps(args) + '\n')
repo = args[args.index('--repo') + 1].split('/')[-1] if '--repo' in args else ''
mode = os.environ.get('SCENARIO', '')
def stamp(seconds):
    return (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=seconds)).strftime('%Y-%m-%dT%H:%M:%SZ')
def run():
    result = {'status':'completed', 'conclusion':'success', 'createdAt':stamp(30), 'url':'https://example.invalid/run'}
    if repo == 'manifold-eval':
        if mode == 'red': result['conclusion'] = 'failure'
        if mode == 'pending': result['status'] = 'in_progress'
        if mode == 'stale': result['createdAt'] = stamp(864000)
        if mode == 'malformed': return '{bad json'
        if mode == 'missing': return 'null'
        if mode == 'read-error': print(json.dumps(result)); sys.exit(1)
    return json.dumps(result, separators=(',', ':'))
if args[:2] == ['workflow','run']:
    if repo == 'manifold-eval' and mode == 'dispatch-error': sys.exit(1)
    (root / repo).touch()
elif args[:2] == ['run','list']:
    if 'databaseId' in args:
        if repo == 'manifold-eval' and mode == 'prior-error': sys.exit(1)
        print('101' if not (root / repo).exists() or mode == 'timeout' else '202')
    else: print(run())
elif args[:2] == ['run','view']:
    if args[1:3] != ['view','202']: sys.exit('wrong run id')
    if args[args.index('--json')+1] == 'status': print('completed')
    else: print(run())
elif args[0] == 'api':
    if any('/dispatches' in a for a in args):
        if mode == 'dispatch-error' and any('manifold-eval/' in a for a in args): sys.exit(1)
    else: print(stamp(120))
else: sys.exit('unexpected gh args: '+repr(args))
'''


class ConsumerRegistryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'bin').mkdir()
        for name in ('consumer-registry.py', 'consumer-registry.json', 'companion-canary-check.sh', 'dispatch-core-release.sh', 'release-train-check.sh'):
            shutil.copyfile(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        self.path = self.root / 'scripts/consumer-registry.json'
        self.rows = json.loads(self.path.read_text())
        self.command('gh', FAKE_GH)
        self.command('git', '#!/bin/bash\ncase "$*" in *" log "*) date +%s;; *rev-parse*) echo abcdef;; esac\n')
        self.command('sleep', '#!/bin/bash\nexit 0\n')
        self.env = {**os.environ, 'PATH': str(self.root / 'bin') + ':' + os.environ['PATH'], 'FIXTURE': str(self.root), 'GH_TOKEN': 'fixture-only', 'TAG_NAME': 'v0.79.0'}

    def command(self, name, text):
        path = self.root / 'bin' / name
        path.write_text(text)
        path.chmod(0o755)

    def run_script(self, name, *args, scenario=''):
        return subprocess.run(['/bin/bash', str(self.root / 'scripts' / name), *args], env={**self.env, 'SCENARIO': scenario}, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)

    def calls(self):
        return [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]

    def test_registry_and_documentation(self):
        result = subprocess.run(['python3', str(ROOT / 'scripts/consumer-registry.py'), 'check'], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_sabotage_omission_is_documentation_drift(self):
        self.path.write_text(json.dumps(self.rows[:-1]))
        result = subprocess.run(['python3', str(ROOT / 'scripts/consumer-registry.py'), '--registry', str(self.path), 'check'], capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('drift', result.stderr)

    def test_sabotage_empty_duplicate_malformed_and_missing_registry(self):
        for content in ('[]', '{bad', '{}', json.dumps(self.rows + [self.rows[0]])):
            self.path.write_text(content)
            result = self.run_script('companion-canary-check.sh')
            self.assertEqual(result.returncode, 2, result.stdout)
            self.assertIn('registry', result.stdout)
            self.assertFalse((self.root / 'calls').exists())
        self.path.unlink()
        self.assertEqual(self.run_script('dispatch-core-release.sh').returncode, 2)

    def test_new_consumer_reaches_all_release_paths(self):
        self.rows.append({**self.rows[0], 'repo':'new-consumer'})
        self.path.write_text(json.dumps(self.rows))
        result = self.run_script('dispatch-core-release.sh')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(any('repos/ManifoldKit/new-consumer/dispatches' in call for call in self.calls()))
        result = self.run_script('companion-canary-check.sh', '--dispatch')
        self.assertEqual(result.returncode, 0, result.stdout)
        for row in self.rows:
            self.assertIn(row['repo'] + '  PASS', result.stdout)
        views = [c for c in self.calls() if c[:2] == ['run', 'view'] and 'conclusion,status,createdAt,url' in c]
        self.assertEqual(len(views), 4)
        self.assertTrue(all(c[2] == '202' for c in views))
        result = subprocess.run(['python3', str(self.root / 'scripts/consumer-registry.py'), 'matrix'], capture_output=True, text=True, timeout=10)
        self.assertIn('new-consumer', json.loads(result.stdout)['companion'])
        self.pin_fixtures()
        result = self.run_script('release-train-check.sh', '--fixture-dir', str(self.root))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('PASS: new-consumer core-pin', result.stdout)
        self.assertIn('PASS: new-consumer release-pr-age', result.stdout)

    def pin_fixtures(self):
        (self.root / 'version.txt').write_text('0.79.0')
        (self.root / 'readme.md').write_text('from: "0.79.0" // x-release-please-version')
        for row in self.rows:
            pin = 'exact: "0.79.0"' if row['pin'] == 'exact' else '.upToNextMinor(from: "0.79.0")'
            (self.root / (row['repo'] + '-package.swift')).write_text('.package(url: "https://github.com/ManifoldKit/ManifoldKit.git", ' + pin + ')')
            (self.root / (row['repo'] + '-open-prs.json')).write_text('[]')

    def test_sabotage_eval_pin_and_stale_bump_fail(self):
        self.pin_fixtures()
        (self.root / 'manifold-eval-package.swift').write_text('.package(url: "https://github.com/ManifoldKit/ManifoldKit.git", exact: "0.78.0")')
        (self.root / 'manifold-eval-open-prs.json').write_text('[{"createdAt":"2020-01-01T00:00:00Z","number":42}]')
        result = self.run_script('release-train-check.sh', '--fixture-dir', str(self.root))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('DRIFT: manifold-eval core-pin', result.stdout)
        self.assertIn('DRIFT: manifold-eval release-pr-age', result.stdout)

    def test_sabotage_eval_terminal_and_freshness_failures(self):
        for scenario in ('red', 'pending', 'stale', 'malformed', 'missing', 'read-error'):
            with self.subTest(scenario=scenario):
                result = self.run_script('companion-canary-check.sh', scenario=scenario)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertNotIn('manifold-eval  PASS', result.stdout)
                self.assertIn('manifold-eval', result.stdout)

    def test_dispatch_failures_and_timeout_never_grade_old_green(self):
        for scenario in ('dispatch-error', 'prior-error', 'timeout'):
            with self.subTest(scenario=scenario):
                result = self.run_script('companion-canary-check.sh', '--dispatch', scenario=scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('ERROR:', result.stdout)
                self.assertNotIn('  PASS', result.stdout)

    def test_release_dispatch_attempts_consumers_after_failure(self):
        self.rows.append({**self.rows[0], 'repo':'after-eval'})
        self.path.write_text(json.dumps(self.rows))
        result = self.run_script('dispatch-core-release.sh', scenario='dispatch-error')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('PASS: dispatched core-release (v0.79.0) to after-eval', result.stdout)
        self.assertIn('ERROR: core-release dispatch failed for: manifold-eval', result.stdout)

    def test_workflow_entrypoints_use_registry(self):
        release = (ROOT / '.github/workflows/release-please.yml').read_text().split('  notify-companions:')[1]
        self.assertIn('actions/checkout@', release)
        self.assertIn('bash scripts/dispatch-core-release.sh', release)
        compat = (ROOT / '.github/workflows/companion-compat.yml').read_text()
        self.assertIn('python3 scripts/consumer-registry.py matrix', compat)
        self.assertIn('matrix: ${{ fromJSON(needs.consumers.outputs.matrix) }}', compat)
        lint = (ROOT / '.github/workflows/lint.yml').read_text()
        self.assertIn('python3 scripts/tests/test_consumer_registry.py', lint)
        self.assertIn('bash scripts/companion-canary-check.sh --dispatch', lint)
        self.assertIn('merge_group:', lint)


if __name__ == '__main__':
    unittest.main()
