#!/usr/bin/env node
// scripts/changelog-parser-check/check.mjs
//
// #2380: release-please's commit parser (@conventional-commits/parser, via
// release-please's own parseConventionalCommits) can hard-fail on a
// squashed commit body. Confirmed root cause: an identifier immediately
// followed by NESTED parentheses -- e.g. Swift code quoted in a commit
// body like `exit(FuzzReport.exitCode(for: report))`. The exception is
// caught internally by release-please and logged only at `debug` level,
// so it silently drops the ENTIRE commit from the generated changelog
// with no warning anywhere in normal output. PR #2375's 223-line squashed
// body hit this exact pattern on line 124.
//
// This check re-runs the SAME parser release-please uses over every
// releasable-type commit in a range and reds on any commit release-please
// itself would silently drop. Unlike scripts/changelog-coverage-check.sh
// (which compares against CHANGELOG.md's TEXT and therefore only means
// anything while that text is release-please's own generated bullets --
// see AGENTS.md § Release workflow), this check never looks at
// CHANGELOG.md's content at all, so it has no editorial-omission
// false-positive surface and can run on ANY push by ANY actor, including
// the operator's own Prisma-rewrite commits -- the git history the parser
// sees doesn't change just because the changelog prose does.
//
// Usage: node check.mjs [BASE_TAG] [HEAD_REF]
//   BASE_TAG  defaults to the previous version found in the repo's
//             CHANGELOG.md's second `## [x.y.z]` header, prefixed with "v"
//             (same convention scripts/changelog-coverage-check.sh uses).
//   HEAD_REF  defaults to HEAD.
//
// Exit 0 = every releasable commit in range parses. Exit 1 = at least one
// doesn't (or the range/config couldn't be resolved -- never silently
// short-circuits to a zero-commit "pass").

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { parseConventionalCommits } from 'release-please/build/src/commit.js';
import { parser as rawParser } from '@conventional-commits/parser';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..', '..');

function fail(msg) {
  console.error(`::error::changelog-parser-check: ${msg}`);
  process.exit(1);
}

function git(args) {
  return execFileSync('git', ['-C', repoRoot, ...args], { encoding: 'utf8' });
}

const changelogPath = path.join(repoRoot, 'CHANGELOG.md');
const configPath = path.join(repoRoot, 'release-please-config.json');

let baseTag = process.argv[2];
const headRef = process.argv[3] || 'HEAD';

if (!baseTag) {
  const changelog = readFileSync(changelogPath, 'utf8');
  const headers = [...changelog.matchAll(/^## \[(\d+\.\d+\.\d+)\]/gm)];
  if (headers.length < 2) {
    fail(`could not derive BASE_TAG from ${changelogPath} (pass it explicitly as argv[2])`);
  }
  baseTag = `v${headers[1][1]}`;
}

try {
  git(['rev-parse', '--verify', '--quiet', `${baseTag}^{commit}`]);
} catch {
  fail(`BASE_TAG '${baseTag}' does not resolve to a commit`);
}

// Scope filter, not a false-positive dodge: a hidden-type commit (e.g.
// chore:) was never going into the changelog, so it failing to parse isn't
// the #2380 defect -- only a commit release-please would actually publish
// can be "silently dropped" from what it publishes. Read dynamically from
// release-please-config.json rather than hardcoded, so a type later
// un-hidden there is automatically covered here too -- intentional, not a
// surprise: if that ever happens, this check's scope widens in lockstep
// with what actually ships in the changelog.
const config = JSON.parse(readFileSync(configPath, 'utf8'));
const sections = config.packages['.']['changelog-sections'];
const visibleTypes = new Set(sections.filter((s) => !s.hidden).map((s) => s.type));
if (visibleTypes.size === 0) {
  fail(`no visible changelog-sections types found in ${configPath}`);
}

const RECORD_SEP = '\x1f';
const log = git(['log', '--no-merges', `--format=%H${RECORD_SEP}%s`, `${baseTag}..${headRef}`]).trim();
if (!log) {
  fail(`no commits found in range ${baseTag}..${headRef} -- refusing to report a vacuous pass`);
}

const headerRe = /^([a-zA-Z]+)(\([^)]*\))?!?:/;

let checked = 0;
const failures = [];

for (const line of log.split('\n')) {
  if (!line) continue;
  const sepIndex = line.indexOf(RECORD_SEP);
  const sha = line.slice(0, sepIndex);
  const subject = line.slice(sepIndex + 1);

  const m = subject.match(headerRe);
  if (!m) continue;
  const type = m[1];
  if (!visibleTypes.has(type)) continue;

  checked++;

  const fullMessage = git(['log', '-1', '--format=%B', sha]);

  // parseConventionalCommits() catches its own parse errors internally and
  // only logs them at `debug` level -- it never throws and never surfaces
  // the underlying line:column, which is exactly the silence this check
  // exists to break. A commit it drops comes back as zero entries.
  const parsed = parseConventionalCommits([
    { sha, message: fullMessage, files: [], pullRequest: null },
  ]);

  if (parsed.length === 0) {
    // Re-run the raw grammar directly (bypassing release-please's swallowed
    // wrapper) to recover the actual line:column and construct that broke
    // it, so whoever hits this knows exactly what to reword.
    let detail = '(parser produced zero entries with no recoverable detail)';
    try {
      rawParser(fullMessage);
    } catch (rawErr) {
      detail = rawErr.message;
    }
    failures.push({ sha: sha.slice(0, 8), subject, detail });
  }
}

if (checked === 0) {
  fail(
    `matched 0 releasable commits in ${baseTag}..${headRef} -- the header regex or visible-types list is likely broken, not that nothing shipped`
  );
}

if (failures.length > 0) {
  console.error(
    `::error::changelog-parser-check: release-please's own commit parser cannot parse ${failures.length} of ${checked} releasable commit(s) in ${baseTag}..${headRef} -- release-please would silently DROP these from the changelog with no warning:`
  );
  for (const f of failures) {
    console.error(`::error::  ${f.sha} ${f.subject}`);
    console.error(`::error::    parser error: ${f.detail}`);
  }
  console.error('');
  console.error('This is the #2380 defect itself, not just a symptom. Reword the offending');
  console.error('construct in the commit body (commonly: an identifier immediately followed');
  console.error('by NESTED parentheses, e.g. `exit(FuzzReport.exitCode(for: report))` --');
  console.error('add a space, back-tick it, or restructure the sentence) and amend/re-squash.');
  process.exit(1);
}

const releasePleaseVersion = JSON.parse(
  readFileSync(path.join(__dirname, 'node_modules', 'release-please', 'package.json'), 'utf8')
).version;

console.log(
  `✓ changelog-parser-check: all ${checked} releasable commit(s) in ${baseTag}..${headRef} parse cleanly with release-please's own commit parser (release-please v${releasePleaseVersion})`
);
