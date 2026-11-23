import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { classifyPath, selectJobs, selectBase, decide, parseNameStatus, SCOPED, REQUIRED } from './post_merge_scope.mjs';

const repo = 'pietro1704/Epub-to-Mp3';
const sha = 'c'.repeat(40);
const all = Object.fromEntries(Object.keys(SCOPED).map(name => [name, true]));
const none = Object.fromEntries(Object.keys(SCOPED).map(name => [name, false]));
const modified = (...paths) => paths.map(path => ({ status: 'M', path }));

test('only confined areas are recognized; everything else is shared', () => {
  assert.equal(classifyPath('ios/EpubToMp3/EpubToMp3/App.swift'), 'apple');
  assert.equal(classifyPath('flutter_app/lib/main.dart'), 'flutter');
  for (const path of ['docs/agents/memory.md', 'CLAUDE.md', 'AGENTS.md', 'CODING_STANDARDS.md', 'CONTEXT.md']) assert.equal(classifyPath(path), 'docs');
  for (const path of ['README.md', 'CHANGELOG.md', 'SECURITY.md', 'ruby_app/rails_gateway/public/sample.epub', 'docs/image.png',
    'crates/converter-core/src/lib.rs', 'native/x.c', 'scripts/native_job.rb', 'mise.toml', 'Cargo.lock', '.github/workflows/ci.yml',
    'Dockerfile', 'tests/fixture.epub', '.gitignore', 'ios/Other.swift', 'crates/README.md', 'ios/EpubToMp3']) {
    assert.equal(classifyPath(path), 'shared', path);
  }
  for (const status of ['A', 'D', 'R100', 'C', 'U', 'X']) assert.equal(classifyPath('CLAUDE.md', status), 'shared', status);
});

test('a validation is skipped only when no change touches its areas or a shared path', () => {
  assert.deepEqual(selectJobs(modified('docs/a.md', 'CLAUDE.md')), none);
  assert.deepEqual(selectJobs(modified('ios/EpubToMp3/a.swift')), { ...none, faber: true, isolation: true });
  assert.deepEqual(selectJobs(modified('flutter_app/a.dart')), { ...none, faber: true, flutter: true, linux: true });
  for (const shared of ['ruby_app/rails_gateway/public/sample.epub', 'README.md', 'scripts/x.rb']) {
    assert.deepEqual(selectJobs(modified('ios/EpubToMp3/a.swift', shared)), all, shared);
  }
  assert.deepEqual(selectJobs([{ status: 'A', path: 'ios/EpubToMp3/new.swift' }, { status: 'D', path: 'docs/old.md' }]), { ...none, faber: true, isolation: true });
  assert.deepEqual(selectJobs([{ status: 'D', path: 'CLAUDE.md' }]), all, 'Deleting a root marker is shared');
  assert.deepEqual(selectJobs([], { full: true }), all);
  assert.deepEqual(selectJobs([]), none, 'An empty diff since a validated ancestor changes nothing');
  assert.deepEqual(parseNameStatus('M\0ios/EpubToMp3/a.swift\0D\0docs/x.md\0'),
    [{ status: 'M', path: 'ios/EpubToMp3/a.swift' }, { status: 'D', path: 'docs/x.md' }]);
  assert.throws(() => parseNameStatus('M\0'), /Malformed/);
});

const run = (id, head, patch = {}) => ({ id, head_sha: head, status: 'completed', conclusion: 'success', event: 'push',
  head_branch: 'master', repository: { full_name: repo }, head_repository: { full_name: repo }, ...patch });

test('the base is the newest successful trusted validation of a strict ancestor', () => {
  const a = 'a'.repeat(40), b = 'b'.repeat(40), d = 'd'.repeat(40);
  const ancestors = new Set([sha, a, b]);
  assert.equal(selectBase({ sha, repo, ancestors, runs: [run(1, a), run(2, b), run(3, d)] }), b);
  assert.equal(selectBase({ sha, repo, ancestors, runs: [run(1, a), run(2, b, { conclusion: 'failure' })] }), a);
  for (const patch of [{ conclusion: 'cancelled' }, { status: 'in_progress' }, { event: 'pull_request' }, { head_branch: 'feature' },
    { repository: { full_name: 'other/repo' } }, { head_repository: { full_name: 'fork/repo' } }, { head_sha: sha }]) {
    assert.equal(selectBase({ sha, repo, ancestors, runs: [run(1, patch.head_sha ?? a, patch)] }), null, JSON.stringify(patch));
  }
  assert.equal(selectBase({ sha, repo, ancestors: new Set([sha]), runs: [run(1, a)] }), null);
});

test('dispatch, a missing base, or unavailable metadata select everything', () => {
  const a = 'a'.repeat(40);
  const git = (diff) => args => args[0] === 'rev-list' ? { status: 0, stdout: `${sha}\n${a}\n` } : diff;
  assert.deepEqual(decide({ sha, repo, event: 'workflow_dispatch', api: () => { throw new Error('unused'); } }).jobs, all);
  assert.deepEqual(decide({ sha, repo, event: 'push', api: () => ({ workflow_runs: [] }), run: git() }).jobs, all);
  assert.throws(() => decide({ sha, repo, event: 'push', api: () => ({}) }), /history/);
  const result = decide({ sha, repo, event: 'push', api: () => ({ workflow_runs: [run(1, a)] }),
    run: git({ status: 0, stdout: 'M\0ios/EpubToMp3/a.swift\0M\0docs/x.md\0' }) });
  assert.equal(result.base, a);
  assert.deepEqual(result.jobs, { ...none, faber: true, isolation: true });
  assert.throws(() => decide({ sha, repo, event: 'push', api: () => ({ workflow_runs: [run(1, a)] }), run: git({ status: 128, stdout: '' }) }), /diff/);
  assert.throws(() => decide({ sha, repo, event: 'push', api: () => ({ workflow_runs: [run(1, a)] }), run: () => ({ status: 128, stdout: '' }) }), /history/);
});

// A job may skip an area only when nothing it runs reads that area.
test('confined trees are read only by validations their area selects', () => {
  const confined = { apple: 'ios/EpubToMp3', flutter: 'flutter_app' };
  const post = readFileSync('.github/workflows/post-merge-validation.yml', 'utf8');
  for (const [job, areas] of Object.entries(SCOPED)) {
    const uses = post.match(new RegExp(`\\n  ${job}:\\n(?:    .*\\n)*?    uses: \\./\\.github/workflows/([\\w.-]+)`))?.[1];
    assert.ok(uses, job);
    const seen = new Set(); const queue = [uses]; let text = '';
    while (queue.length) {
      const file = queue.shift(); if (seen.has(file)) continue; seen.add(file);
      const body = readFileSync(`.github/workflows/${file}`, 'utf8'); text += body;
      for (const match of body.matchAll(/uses: \.\/\.github\/workflows\/([\w.-]+)/g)) queue.push(match[1]);
    }
    for (const [area, tree] of Object.entries(confined)) {
      if (areas.includes(area)) continue;
      assert.ok(!text.includes(tree), `${job} (${[...seen].join(', ')}) reads ${tree} but ${area} does not select it`);
    }
  }
  for (const tree of Object.values(confined)) {
    const grep = spawnSync('git', ['grep', '-l', '-F', `${tree}/`, '--', 'crates', 'native', 'ruby_app', 'Dockerfile', '.dockerignore', 'tests'], { encoding: 'utf8' });
    assert.equal(grep.stdout.trim(), '', `Shared code reads ${tree}`);
  }
  assert.ok(REQUIRED.includes('scope') && REQUIRED.includes('merge'));
});

test('a dispatch is scoped only when the batch asks for it', () => {
  const sha = 'a'.repeat(40), base = 'b'.repeat(40);
  const api = () => ({ workflow_runs: [{ id: 1, head_sha: base, status: 'completed', conclusion: 'success', event: 'workflow_dispatch',
    head_branch: 'master', repository: { full_name: repo }, head_repository: { full_name: repo } }] });
  const run = args => args[0] === 'rev-list' ? { status: 0, stdout: `${sha}\n${base}\n` } : { status: 0, stdout: 'M\0docs/a.md\0' };
  assert.deepEqual(decide({ sha, repo, event: 'workflow_dispatch', api, run }).jobs, all, 'plain dispatch runs everything');
  const scoped = decide({ sha, repo, event: 'workflow_dispatch', scopedDispatch: true, api, run });
  assert.equal(scoped.base, base);
  assert.deepEqual(scoped.jobs, none);
  assert.deepEqual(decide({ sha, repo, event: 'schedule', scopedDispatch: true, api, run }).jobs, all);
});
