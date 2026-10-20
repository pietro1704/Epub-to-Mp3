import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { validatedMerge } from './validated_merge.mjs';
const sha = 'a'.repeat(40), tip = 'b'.repeat(40), repo = 'owner/project';
function fixture() {
  const run = { id: 12, workflow_id: 7, head_sha: sha, event: 'push', head_branch: 'master', repository: { full_name: repo }, head_repository: { full_name: repo }, run_attempt: 1, status: 'completed', conclusion: 'success' };
  return { workflow: { id: 7, name: 'Post-merge validation', path: '.github/workflows/post-merge-validation.yml', state: 'active' }, runs: [run], run: structuredClone(run), master: sha,
    prs: [{ merged_at: '2026-10-20T12:00:00Z', state: 'closed', merge_commit_sha: sha, base: { ref: 'master', repo: { full_name: repo } } }], comparison: { status: 'identical', behind_by: 0 }, tagSha: sha };
}
function client(f) {
  return async path => {
    assert.ok(path.startsWith(`/repos/${repo}/`));
    const route = path.slice(`/repos/${repo}`.length);
    if (route === `/commits/${sha}`) return { sha };
    if (route === '/commits/v1.2.3') return { sha: f.tagSha };
    if (route === '/actions/workflows/post-merge-validation.yml') return f.workflow;
    if (route.startsWith('/actions/workflows/7/runs?')) return { workflow_runs: f.runs, total_count: f.runs?.length };
    if (route === '/actions/runs/12') return f.run;
    if (route.startsWith(`/commits/${sha}/pulls?`)) return f.prs;
    if (route === '/git/ref/heads/master') return { object: { sha: f.master } };
    if (route === `/compare/${sha}...${f.master}`) return f.comparison;
    throw Error(`Unexpected API request: ${route}`);
  };
}
const verify = (f, extra = {}) => validatedMerge({ repo, ref: sha, api: client(f), ...extra });
test('dispatched post-merge validation accepts only a successful exact confirmed merge', async () => {
  const f = fixture();
  f.runs[0].event = 'workflow_dispatch';
  f.run.event = 'workflow_dispatch';
  assert.equal((await verify(f, { latest: true })).sha, sha);
  f.run.conclusion = 'failure';
  await assert.rejects(verify(f), /unsuccessful|stale/);
  f.run.conclusion = 'success';
  f.prs[0].merge_commit_sha = tip;
  await assert.rejects(verify(f), /confirmed master merge/);
});
test('only successful exact merged revision is accepted; historical release stays possible', async () => {
  const f = fixture(); assert.equal((await verify(f, { latest: true, tag: 'v1.2.3' })).sha, sha);
  f.master = tip; f.comparison.status = 'ahead';
  assert.equal((await verify(f, { tag: 'v1.2.3' })).master, tip);
  await assert.rejects(verify(f, { latest: true }), /superseded/);
});
test('failed, cancelled, skipped and incomplete validation fail closed', async () => {
  for (const conclusion of ['failure', 'cancelled', 'skipped', 'neutral', null, 'timed_out', 'action_required']) {
    const f = fixture(); f.run.conclusion = conclusion; await assert.rejects(verify(f));
  }
  const f = fixture(); f.run.status = 'in_progress'; await assert.rejects(verify(f));
});
test('repository, SHA, branch, event, workflow and attempt identities cannot be substituted', async () => {
  for (const [key, value] of Object.entries({ workflow_id: 8, head_sha: tip, event: 'pull_request', head_branch: 'feature/unsafe', repository: { full_name: 'fork/project' }, head_repository: { full_name: 'fork/project' }, id: null, run_attempt: null })) {
    const f = fixture(); f.runs[0][key] = value; await assert.rejects(verify(f), /No trusted/);
  }
  for (const [key, value] of Object.entries({ id: 0, name: 'CI', path: '.github/workflows/other.yml', state: 'disabled_manually' })) {
    const f = fixture(); f.workflow[key] = value; await assert.rejects(verify(f));
  }
});
test('missing history, newer failed run, or a rerun begun after selection blocks publication', async () => {
  const empty = fixture(); empty.runs = []; await assert.rejects(verify(empty));
  const rerun = fixture(); rerun.run.run_attempt = 2; await assert.rejects(verify(rerun), /stale/);
  const newer = fixture(); newer.runs.push({ ...newer.run, id: 13 });
  const api = client(newer);
  await assert.rejects(validatedMerge({ repo, ref: sha, api: path => path.endsWith('/actions/runs/13') ? { ...newer.run, id: 13, conclusion: 'failure' } : api(path) }));
});
test('PR must be confirmed merged into this master at the exact commit', async () => {
  for (const mutate of [f => f.prs = [], f => f.prs[0].merged_at = null, f => f.prs[0].state = 'open', f => f.prs[0].merge_commit_sha = tip, f => f.prs[0].base.ref = 'develop', f => f.prs[0].base.repo.full_name = 'fork/project']) {
    const f = fixture(); mutate(f); await assert.rejects(verify(f), /confirmed master merge/);
  }
});
test('rewritten history and a moved tag cannot inherit old validation', async () => {
  const f = fixture(); f.comparison = { status: 'diverged', behind_by: 1 }; await assert.rejects(verify(f), /reachable/);
  const moved = fixture(); moved.tagSha = tip; await assert.rejects(verify(moved, { tag: 'v1.2.3' }), /Tag differs/);
});
test('rechecking publication after master advances rejects a previously accepted HF snapshot', async () => {
  const f = fixture(); await verify(f, { latest: true }); f.master = tip; f.comparison.status = 'ahead';
  await assert.rejects(verify(f, { latest: true }), /superseded/);
});
test('metadata errors and malformed responses block before returning a source', async () => {
  await assert.rejects(validatedMerge({ repo, ref: sha, api: () => { throw Error('offline'); } }), /offline/);
  const f = fixture(); f.runs = null; await assert.rejects(verify(f), /Incomplete/);
  const good = fixture(), api = client(good);
  await assert.rejects(validatedMerge({ repo, ref: sha, api: async path => {
    const response = await api(path);
    return path.includes('/runs?') ? { ...response, total_count: 3 } : response;
  } }), /Incomplete run history/);
});
test('publisher boundaries preserve manual releases and serialize HF writes', () => {
  const workflow = name => readFileSync(new URL(`../.github/workflows/${name}.yml`, import.meta.url), 'utf8');
  for (const name of ['auto-release', 'ios-testflight', 'rollback-hf']) {
    assert.match(workflow(name), /workflow_dispatch:/); assert.doesNotMatch(workflow(name), /^  workflow_run:|^  push:/m);
  }
  assert.match(workflow('sync-hf'), /workflows: \["Post-merge validation"\]/);
  for (const name of ['sync-hf', 'rollback-hf']) {
    assert.match(workflow(name), /group: sync-hf\n  cancel-in-progress: false/);
    assert.match(workflow(name), /RUNNER_TEMP\/validated_merge\.mjs/);
  }
  const release = workflow('release-desktop');
  assert.match(release, /needs: \[gate, docker, android, swiftui-apple, flutter-desktop\]/);
  assert.doesNotMatch(release, /push: true|softprops\/action-gh-release/);
  assert.doesNotMatch(workflow('auto-release'), /checkout_ref="master"|rolling rebuild/);
});

test('actual CLI exports only its validated immutable SHA through read-only mocked gh calls', async () => {
  const { mkdtempSync, mkdirSync, writeFileSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join, dirname } = await import('node:path');
  const { fileURLToPath } = await import('node:url');
  const { spawnSync } = await import('node:child_process');
  const directory = mkdtempSync(join(tmpdir(), 'validated-merge-cli-'));
  try {
    const bin = join(directory, 'bin'); mkdirSync(bin);
    const f = fixture(), prefix = `/repos/${repo}`;
    const responses = {
      [`${prefix}/commits/${sha}`]: { sha },
      [`${prefix}/actions/workflows/post-merge-validation.yml`]: f.workflow,
      [`${prefix}/actions/workflows/7/runs?head_sha=${sha}&per_page=100&page=1`]: { workflow_runs: f.runs, total_count: 1 },
      [`${prefix}/actions/runs/12`]: f.run,
      [`${prefix}/commits/${sha}/pulls?per_page=100&page=1`]: f.prs,
      [`${prefix}/git/ref/heads/master`]: { object: { sha } },
      [`${prefix}/compare/${sha}...${sha}`]: f.comparison,
    };
    const metadata = join(directory, 'metadata.json'), output = join(directory, 'output'), calls = join(directory, 'calls');
    writeFileSync(metadata, JSON.stringify(responses));
    writeFileSync(join(bin, 'gh'), `#!${process.execPath}\n` + `
      const fs = require('node:fs');
      const args = process.argv.slice(2);
      fs.appendFileSync(process.env.CALLS, JSON.stringify(args) + '\\n');
      if (args.length !== 2 || args[0] !== 'api') process.exit(77);
      const response = JSON.parse(fs.readFileSync(process.env.METADATA))[args[1]];
      if (!response) process.exit(78);
      process.stdout.write(JSON.stringify(response));
    `, { mode: 0o755 });
    const result = spawnSync(process.execPath, [fileURLToPath(new URL('./validated_merge.mjs', import.meta.url)), '--repo', repo, '--ref', sha, '--latest'], {
      encoding: 'utf8', env: { PATH: `${bin}:${dirname(process.execPath)}`, METADATA: metadata, CALLS: calls, GITHUB_OUTPUT: output },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout).sha, sha);
    assert.equal(readFileSync(output, 'utf8'), `sha=${sha}\n`);
    assert.ok(readFileSync(calls, 'utf8').trim().split('\n').map(JSON.parse).every(args => args.length === 2 && args[0] === 'api' && args[1].startsWith(prefix)));
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('mid-check reruns, moved tags and master advancement invalidate publication authorization', async () => {
  for (const kind of ['run', 'tag', 'master']) {
    const f = fixture(), original = client(f); let reads = 0;
    const watched = kind === 'run' ? '/actions/runs/12' : kind === 'tag' ? '/commits/v1.2.3' : '/git/ref/heads/master';
    const api = async path => {
      if (path.endsWith(watched) && ++reads === 2) {
        if (kind === 'run') return { ...f.run, run_attempt: 2, status: 'in_progress', conclusion: null };
        if (kind === 'tag') return { sha: tip };
        return { object: { sha: tip } };
      }
      return original(path);
    };
    await assert.rejects(validatedMerge({ repo, ref: sha, tag: 'v1.2.3', latest: true, api }), /changed|advanced/);
  }
});

test('Auto Release tags the validated SHA explicitly and refuses unvalidated or conflicting identities', async () => {
  const { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { spawnSync } = await import('node:child_process');
  const workflow = readFileSync(new URL('../.github/workflows/auto-release.yml', import.meta.url), 'utf8');
  const block = workflow.match(/      - name: Create release tag\n[\s\S]*?        run: \|\n([\s\S]*?)(?=\n      - name:)/)?.[1];
  assert.ok(block);
  const script = block.split('\n').map(line => line.replace(/^          /, '')).join('\n');
  assert.doesNotMatch(script, /\$\{\{/);
  const directory = mkdtempSync(join(tmpdir(), 'validated-version-tag-'));
  try {
    const bin = join(directory, 'bin'); mkdirSync(bin);
    const calls = join(directory, 'calls');
    writeFileSync(join(bin, 'git'), `#!${process.execPath}\n` + `
      const fs = require('node:fs'); const args = process.argv.slice(2);
      fs.appendFileSync(process.env.CALLS, JSON.stringify(args) + '\\n');
      if (args[0] === 'rev-parse') {
        if (!process.env.EXISTING_SHA) process.exit(1);
        process.stdout.write(process.env.EXISTING_SHA + '\\n');
      }
    `, { mode: 0o755 });
    const invoke = (version, identity, existing = '') => spawnSync('/bin/bash', ['--noprofile', '--norc', '-c', script], { encoding: 'utf8', env: { PATH: bin, CALLS: calls, VERSION_TAG: version, VALIDATED_SHA: identity, EXISTING_SHA: existing } });
    let result = invoke('v1.2.3', sha); assert.equal(result.status, 0, result.stderr);
    const commands = readFileSync(calls, 'utf8').trim().split('\n').map(JSON.parse);
    assert.deepEqual(commands.slice(-2), [['tag', '--', 'v1.2.3', sha], ['push', 'origin', 'refs/tags/v1.2.3']]);
    const previous = readFileSync(calls, 'utf8');
    assert.notEqual(invoke('v1.2.3', 'invalid').status, 0);
    assert.notEqual(invoke('v1.2.3;exit 0', sha).status, 0);
    assert.equal(readFileSync(calls, 'utf8'), previous, 'Invalid data must never invoke Git');
    assert.notEqual(invoke('v1.2.3', sha, tip).status, 0, 'An existing tag on another SHA cannot be reused');
    assert.ok(existsSync(calls));
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
