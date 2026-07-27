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
// Usage: node check.mjs [--per-pr] [--repo PATH] [BASE_TAG] [HEAD_REF]
//   --repo    The git repository to read history and release-please-config.json
//             from. Defaults to this script's own repository (two levels up),
//             which is what CI always uses -- lint.yml never passes this
//             flag. It exists so this gate's own test suite can point it at a
//             synthetic fixture repository with known commits: without it, the
//             only testable ranges were this repo's real tags, and the `test`
//             job checks out with `fetch-depth: 2` and no tags, so a
//             tag-anchored range does not resolve there at all (the shape that
//             red-ed ChangelogParserCheckScriptTests on its first real CI
//             run). node_modules is still resolved next to this script, never
//             from --repo, so the pinned release-please version being
//             exercised is always this repo's pinned one.
//   --per-pr  Changes the meaning of "zero releasable commits matched" from
//             a hard failure to an expected, visible pass. Without this
//             flag (the whole-range/release-branch mode), matching zero
//             releasable commits means the header regex or visible-types
//             list broke, since a real release always ships at least one.
//             WITH this flag (per-PR mode), zero is completely normal and
//             common -- e.g. a release-please PR is just one `chore(main):
//             release X` commit (chore is hidden), a Dependabot PR is
//             `chore(deps): bump …` (also hidden), or a branch is entirely
//             non-conventional WIP commits (AGENTS.md § Commit style
//             explicitly permits that pre-squash). Treating that as a red
//             would make the per-PR check block every release PR and every
//             Dependabot PR outright -- exactly the workflow it exists to
//             protect. The whole-range run remains the authoritative sweep
//             regardless of this flag; per-PR is preventive on top of it,
//             not a replacement for it, so relaxing this one guard in this
//             one mode does not reopen a vacuous-pass hole for the #2380
//             defect itself.
//   BASE_TAG  defaults to the previous version found in the repo's
//             CHANGELOG.md's second `## [x.y.z]` header, prefixed with "v"
//             (same convention scripts/changelog-coverage-check.sh uses).
//             Running with this default against a historical commit will
//             permanently red on an already-published defect (e.g. the
//             bare default today derives v0.73.0, whose range still
//             contains f95f6428) -- that's expected for a human poking at
//             it by hand; it self-heals at the next real release. CI *does*
//             use the bare form (lint.yml's whole-range step passes no
//             arguments), but only on the release-please branch, where the
//             derived base is the previous tag -- so an already-published
//             defect falls outside the range instead of reddening it.
//             Verified: v0.74.0..origin/main is clean.
//   HEAD_REF  defaults to HEAD.
//
// Exit 0 = every releasable commit in range parses (or, in --per-pr mode,
// there were none to check). Exit 1 = at least one doesn't, or the
// range/config couldn't be resolved -- never silently short-circuits to a
// zero-commit "pass" in whole-range mode.

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { parseConventionalCommits } from 'release-please/build/src/commit.js';
import { parser as rawParser } from '@conventional-commits/parser';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function fail(msg) {
  console.error(`::error::changelog-parser-check: ${msg}`);
  process.exit(1);
}

const rawArgs = process.argv.slice(2);
const perPrIndex = rawArgs.indexOf('--per-pr');
const perPr = perPrIndex !== -1;
let positional = perPr ? [...rawArgs.slice(0, perPrIndex), ...rawArgs.slice(perPrIndex + 1)] : rawArgs;

// --repo PATH: see this file's header. Consumed before the positional
// BASE_TAG/HEAD_REF so the two can be combined in any order.
const repoIndex = positional.indexOf('--repo');
let repoRoot = path.resolve(__dirname, '..', '..');
if (repoIndex !== -1) {
  const value = positional[repoIndex + 1];
  if (!value) {
    fail('--repo requires a path argument');
  }
  repoRoot = path.resolve(value);
  positional = [...positional.slice(0, repoIndex), ...positional.slice(repoIndex + 2)];
}

function git(args) {
  return execFileSync('git', ['-C', repoRoot, ...args], { encoding: 'utf8' });
}

// An unresolvable --repo must fail loudly here rather than surface later as a
// confusing "no commits found in range" -- a gate pointed at the wrong tree is
// worse than one that refuses to run.
try {
  git(['rev-parse', '--git-dir']);
} catch {
  fail(`--repo '${repoRoot}' is not a git repository`);
}

const changelogPath = path.join(repoRoot, 'CHANGELOG.md');
const configPath = path.join(repoRoot, 'release-please-config.json');

// An explicitly-passed empty string ("$base_sha" expanding to nothing, a
// caller-side bug) must fail loudly rather than silently fall through to
// the CHANGELOG-derived default and check the wrong, much wider range.
if (positional.length > 0 && positional[0] === '') {
  fail('BASE_TAG was passed as an empty string -- refusing to silently widen to the CHANGELOG-derived default');
}

let baseTag = positional[0];
const headRef = positional[1] || 'HEAD';

if (!baseTag) {
  // Guarded for the same reason configPath is below: without it a --repo
  // target lacking CHANGELOG.md exits on a raw ENOENT stack instead of this
  // gate's own diagnostic. It failed closed either way; this just says why.
  if (!existsSync(changelogPath)) {
    fail(`${changelogPath} not found -- cannot derive BASE_TAG (pass it explicitly as argv[2])`);
  }
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

// Scope filter, not a false-positive dodge: a NON-breaking hidden-type
// commit (e.g. a plain `chore:`) was never going into the changelog, so it
// failing to parse isn't the #2380 defect -- only a commit release-please
// would actually publish can be "silently dropped" from what it publishes.
// Read dynamically from release-please-config.json rather than hardcoded, so
// a type later un-hidden there is automatically covered here too.
//
// A BREAKING hidden-type commit is a different animal and is NOT filtered
// out -- see isBreaking() below. An earlier version of this comment claimed
// hidden-type commits simply "were never going into the changelog"; that is
// false for breaking ones, and verified so against the pinned
// release-please: `chore(deps)!: …` with a clean body parses with
// breaking=true and renders BOTH a `### ⚠ BREAKING CHANGES` entry and a
// `### Chores` bullet, and it drives the version bump. With a
// parser-hostile body it is dropped entirely, taking the breaking notice
// AND the bump with it. Filtering those out by type would have left #2380's
// worst variant uncovered behind a comment asserting it couldn't happen.
if (!existsSync(configPath)) {
  fail(`${configPath} not found -- the visible changelog-sections types cannot be derived, so scope would be guessed rather than read`);
}
const config = JSON.parse(readFileSync(configPath, 'utf8'));
const sections = config.packages['.']['changelog-sections'];
const visibleTypes = new Set(sections.filter((s) => !s.hidden).map((s) => s.type));
if (visibleTypes.size === 0) {
  fail(`no visible changelog-sections types found in ${configPath}`);
}

const RECORD_SEP = '\x1f';
const log = git(['log', '--no-merges', `--format=%H${RECORD_SEP}%s`, `${baseTag}..${headRef}`]).trim();
if (!log) {
  if (perPr) {
    // Same reasoning as the `checked === 0` relaxation below, one step
    // earlier: in per-PR mode an empty `--no-merges` range is a legitimate
    // shape (a PR containing only merge commits), and reddening the required
    // lint check on it would be exactly the false red --per-pr exists to
    // prevent. The whole-range mode below still refuses a vacuous pass.
    console.log(
      `changelog-parser-check: no non-merge commits in ${baseTag}..${headRef} -- nothing to parse in this PR.`
    );
    process.exit(0);
  }
  fail(`no commits found in range ${baseTag}..${headRef} -- refusing to report a vacuous pass`);
}

// `!` is captured (group 3) rather than skipped: it is one of the two ways a
// commit declares itself breaking, and a breaking commit is in scope
// regardless of whether its type is hidden.
const headerRe = /^([a-zA-Z]+)(\([^)]*\))?(!)?:/;

// The other way: a `BREAKING CHANGE:` / `BREAKING-CHANGE:` footer anywhere in
// the body. Both spellings are accepted by the conventional-commits spec and
// by release-please, so both are honoured here.
const breakingFooterRe = /^BREAKING[ -]CHANGE:/m;

let checked = 0;
const failures = [];

for (const line of log.split('\n')) {
  if (!line) continue;
  const sepIndex = line.indexOf(RECORD_SEP);
  const sha = line.slice(0, sepIndex);
  const subject = line.slice(sepIndex + 1);

  // A subject that doesn't match at all (`Revert "feat: x"`, a double-scope
  // `feat(a)(b)!:`) is skipped -- release-please returns zero entries for
  // those too, so they are dropped rather than published-then-lost, which is
  // a different failure than #2380's. Consequence worth stating plainly: "0
  // failures" from this gate means "nothing release-please would publish got
  // silently dropped", NOT "everything in this range was published".
  // commitlint gates PR titles and direct pushes to main are blocked, which
  // is what keeps that gap narrow.
  const m = subject.match(headerRe);
  if (!m) continue;
  const type = m[1];
  const bangInHeader = m[3] === '!';

  // Fetched before the scope decision, not after: deciding whether a
  // hidden-type commit is breaking requires its body (the footer form).
  const fullMessage = git(['log', '-1', '--format=%B', sha]);
  const isBreaking = bangInHeader || breakingFooterRe.test(fullMessage);

  // In scope if release-please would publish it: a visible type, or ANY
  // breaking commit (a breaking `chore!:` renders under ⚠ BREAKING CHANGES
  // and drives the version bump even though `chore` is hidden).
  if (!visibleTypes.has(type) && !isBreaking) continue;

  checked++;

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
  if (perPr) {
    // Normal and common in per-PR mode -- a release-please PR is one
    // hidden-type `chore(main): release X` commit, a Dependabot PR is
    // `chore(deps): bump …` (also hidden), and AGENTS.md § Commit style
    // explicitly permits non-conventional WIP commits pre-squash. None of
    // that is the #2380 defect; there is simply nothing releasable here
    // for the parser to have a verdict on. The whole-range run (no
    // --per-pr) remains the authoritative sweep and keeps the strict
    // zero-means-broken guard below.
    console.log(
      `changelog-parser-check: no releasable commits in ${baseTag}..${headRef} -- nothing to parse in this PR.`
    );
    process.exit(0);
  }
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
  console.error('construct in the commit body and amend/re-squash. The usual cause is a body');
  console.error('line that BEGINS with an identifier immediately followed by NESTED');
  console.error('parentheses, e.g. a line starting `exit(FuzzReport.exitCode(for: report))`.');
  console.error('');
  console.error('Fixes verified against the pinned parser — indent the line by two spaces,');
  console.error('turn it into a `- ` bullet, put any words in front of it, or un-nest the');
  console.error('call. Back-ticking it and adding a space before the inner `(` do NOT help,');
  console.error('and neither does a fenced code block: the grammar only stops treating the');
  console.error('text as a footer-ish token when the line does not START with the construct.');
  process.exit(1);
}

const releasePleaseVersion = JSON.parse(
  readFileSync(path.join(__dirname, 'node_modules', 'release-please', 'package.json'), 'utf8')
).version;

console.log(
  `✓ changelog-parser-check: all ${checked} releasable commit(s) in ${baseTag}..${headRef} parse cleanly with release-please's own commit parser (release-please v${releasePleaseVersion})`
);
