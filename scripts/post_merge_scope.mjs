#!/usr/bin/env node
// Select the post-merge validations a merge must run. A platform validation may
// be skipped only when every change since the newest successful post-merge
// validation of an ancestor commit is confined to other areas; anything
// unrecognized, any API or Git doubt, and workflow_dispatch select everything.
import { spawnSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SHA = /^[a-f0-9]{40}$/;
const ensure = (condition, message) => { if (!condition) throw new Error(message); };

// Confined areas: trees that no job outside their own surface reads (checked by
// test_post_merge_scope.mjs). Every other path (scripts, workflows, mise, Cargo,
// crates, native, Docker, ruby_app, README.md, CHANGELOG.md, ...) is shared:
// ruby_app fixtures feed Rust and Flutter tests and README.md feeds the HF
// snapshot, so they select every validation.
export const PROSE = Object.freeze(['AGENTS.md', 'CLAUDE.md', 'CODING_STANDARDS.md', 'CONTEXT.md']);
export function classifyPath(path, status = 'M') {
  ensure(typeof path === 'string' && path.length > 0, 'Invalid changed path');
  if (path.startsWith('ios/EpubToMp3/')) return 'apple';
  if (path.startsWith('flutter_app/')) return 'flutter';
  if (path.startsWith('docs/') && path.endsWith('.md')) return 'docs';
  // Adding or deleting a root file can change discovery (CLAUDE.md marks the root).
  if (PROSE.includes(path) && ['M', 'T'].includes(status)) return 'docs';
  return 'shared';
}

// Jobs that always run, then each scoped job and the confined areas that select it.
export const ALWAYS = Object.freeze(['merge', 'scope', 'ci', 'codeql', 'audit', 'ruby']);
export const SCOPED = Object.freeze({
  // Also runs the Mac host tests (formerly `native`) and the adapter isolation XCTest.
  faber: ['apple', 'flutter'],
  flutter: ['flutter'],
  linux: ['flutter'],
  'rails-image': [],
  browser: [],
  snapshot: [],
  ffi: [],
  fallback: [],
  cli: [],
});
export const REQUIRED = Object.freeze([...ALWAYS, ...Object.keys(SCOPED)]);

// changes: [{ status, path }] from git diff --name-status.
export function selectJobs(changes, { full = false } = {}) {
  ensure(Array.isArray(changes), 'Missing changed paths');
  const areas = new Set(changes.map(({ status, path }) => classifyPath(path, status)));
  const everything = full || areas.has('shared');
  return Object.fromEntries(Object.entries(SCOPED).map(([job, surfaces]) => [job, everything || surfaces.some(surface => areas.has(surface))]));
}

// Newest successful post-merge validation of a strict ancestor; null means full.
export function selectBase({ sha, runs, ancestors, repo }) {
  ensure(SHA.test(sha ?? ''), 'Invalid source SHA');
  ensure(Array.isArray(runs) && ancestors instanceof Set, 'Missing validation history');
  const trusted = runs.filter(run => run && run.status === 'completed' && run.conclusion === 'success'
    && ['push', 'workflow_dispatch'].includes(run.event) && run.head_branch === 'master'
    && run.repository?.full_name === repo && run.head_repository?.full_name === repo
    && SHA.test(run.head_sha ?? '') && run.head_sha !== sha && Number.isSafeInteger(run.id));
  for (const run of trusted.sort((a, b) => b.id - a.id)) {
    if (ancestors.has(run.head_sha)) return run.head_sha;
  }
  return null;
}

export function parseNameStatus(output) {
  const fields = output.split('\0').filter(Boolean);
  ensure(fields.length % 2 === 0, 'Malformed integrated diff');
  const changes = [];
  for (let index = 0; index < fields.length; index += 2) changes.push({ status: fields[index], path: fields[index + 1] });
  return changes;
}

function git(args) {
  const result = spawnSync('git', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  ensure(!result.error && !result.signal, 'Git unavailable');
  return result;
}

function gh(path) {
  const result = spawnSync('gh', ['api', path], { encoding: 'utf8', timeout: 30000, maxBuffer: 16 * 1024 * 1024 });
  ensure(!result.error && result.status === 0, 'GitHub metadata unavailable');
  return JSON.parse(result.stdout);
}

const everything = reason => ({ base: null, reason, jobs: selectJobs([], { full: true }) });

export function decide({ sha, event, repo, scopedDispatch = false, api = gh, run = git }) {
  // A dispatch is scoped only when the batch asks for it; any other dispatch runs everything.
  if (event !== 'push' && !(event === 'workflow_dispatch' && scopedDispatch)) return everything(`full validation for ${event}`);
  const response = api(`/repos/${repo}/actions/workflows/post-merge-validation.yml/runs?branch=master&status=success&per_page=100`);
  ensure(Array.isArray(response?.workflow_runs), 'Incomplete validation history');
  const history = run(['rev-list', '--max-count=5000', sha]);
  ensure(history.status === 0, 'Cannot read the integrated history');
  const ancestors = new Set(history.stdout.split('\n').filter(line => SHA.test(line)));
  const base = selectBase({ sha, runs: response.workflow_runs, ancestors, repo });
  if (!base) return everything('no successful ancestor validation');
  const diff = run(['diff', '--no-renames', '--name-status', '-z', base, sha]);
  ensure(diff.status === 0, 'Cannot establish the integrated diff');
  const changes = parseNameStatus(diff.stdout);
  return { base, reason: `changes since ${base}`, changes, jobs: selectJobs(changes) };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let result;
  try {
    result = decide({ sha: process.env.GITHUB_SHA, event: process.env.GITHUB_EVENT_NAME, repo: process.env.GITHUB_REPOSITORY,
      scopedDispatch: process.env.SCOPED_DISPATCH === 'true' });
  } catch (error) {
    // Any doubt selects everything; it never skips.
    result = everything(`full validation: ${error.message}`);
  }
  console.log(JSON.stringify(result, null, 2));
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `selection=${JSON.stringify(result.jobs)}\n`);
}
