'use strict';

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const BOT = 'github-actions[bot]';
const MARKER = '<!-- pr-repair-attempt:v1:';

function command(program, args, options = {}) {
  const result = spawnSync(program, args, { encoding: 'utf8', ...options });
  if (result.error || result.status !== 0) throw new Error(`${program} failed: ${result.error?.message || result.stderr}`);
  return result.stdout;
}

function validate(pr, repository, expected) {
  if (!/^[\da-f]{40}$/.test(expected || '')) throw new Error('Invalid expected SHA');
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository || '')) throw new Error('Invalid repository');
  const author = pr.user?.login;
  const trustedAuthor = author === repository.split('/')[0] ||
    (author === BOT && pr.user?.type === 'Bot');
  const branch = pr.head?.ref || '';
  if (pr.state !== 'open' || pr.draft !== false || pr.base?.ref !== 'master' ||
      pr.base?.repo?.full_name !== repository || pr.head?.repo?.full_name !== repository ||
      pr.head?.sha !== expected || !trustedAuthor ||
      !/^(feature|hermes|bot)\/[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(branch) ||
      branch.includes('..') || branch.includes('//') || branch.endsWith('/') || branch.endsWith('.lock')) {
    throw new Error('PR is outside the trusted current-head repair scope');
  }
  return { number: pr.number, sha: expected, branch };
}

function readiness({ credentials, writers }) {
  return !credentials ? 'blocked_credentials' : !writers ? 'blocked_writers_disabled' : 'prepared';
}

function attempted(comments, sha) {
  return comments.some(comment => comment.user?.login === BOT && comment.user?.type === 'Bot' &&
    comment.body?.startsWith(`${MARKER}${sha} -->`));
}

function protectedPath(filename) {
  return !filename || filename.startsWith('/') || filename.split('/').includes('..') ||
    filename.includes('\\') || /[\x00-\x1f\x7f]/.test(filename) ||
    /(^|\/)(\.git|\.github|\.claude|\.codex|\.agents|\.hermes|\.ssh)(\/|$)/i.test(filename) ||
    /(^|\/)(\.aws|\.azure|\.kube)(\/|$)/i.test(filename) ||
    /(^|\/)\.config\/gcloud(\/|$)/i.test(filename) ||
    /(^|\/)\.docker\/config\.json$/i.test(filename) ||
    /(^|\/)(\.netrc|\.npmrc|\.pypirc|auth\.json)$/i.test(filename) ||
    /(^|\/)(AGENTS\.md|CLAUDE\.md|mise\.toml|\.gitmodules|\.env[^/]*|[^/]*(credential|secret)[^/]*|[^/]*\.(pem|key|p12|mobileprovision))$/i.test(filename) ||
    /^(scripts\/|docs\/agents\/|docs\/agent-workflow\.md|TODO_APP\.md)/.test(filename);
}

function validateChanges(directory, expected) {
  const git = (...args) => command('git', args, { cwd: directory });
  if (git('rev-parse', 'HEAD').trim() !== expected) throw new Error('Repair checkout HEAD changed');
  const status = git('status', '--porcelain=v1', '-z', '--untracked-files=all').split('\0').filter(Boolean);
  if (!status.length) throw new Error('No repair produced');
  for (const entry of status) {
    if (/[RCU]/.test(entry.slice(0, 2)) || protectedPath(entry.slice(3))) {
      throw new Error('Repair changes a protected path, rename, copy or conflict');
    }
    const filename = path.join(directory, entry.slice(3));
    try {
      if (fs.lstatSync(filename).isSymbolicLink()) throw new Error('Untracked or tracked symlink repair refused');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  const modes = git('diff', '--raw', '--no-abbrev', expected, '--').split('\n');
  if (modes.some(line => /^:(160000|120000) |^:\d+ (160000|120000) /.test(line))) throw new Error('Submodule or symlink repair refused');
  for (const entry of git('ls-files', '--stage', '-z').split('\0').filter(Boolean)) {
    if (entry.startsWith('160000 ') && status.some(item => item.slice(3) === entry.split('\t')[1])) {
      throw new Error('Submodule repair refused');
    }
  }
  git('diff', '--check');
}

function client(repository) {
  const prefix = `/repos/${repository}`;
  return function api(endpoint, method = 'GET', body) {
    const args = ['api', `${prefix}${endpoint}`, '--method', method];
    if (body !== undefined) args.push('--input', '-');
    return JSON.parse(command('gh', args, body === undefined ? {} : { input: JSON.stringify(body) }) || 'null');
  };
}

function inspect(api, repository, number, expected) {
  if (!/^[1-9]\d*$/.test(String(number))) throw new Error('Invalid PR number');
  return validate(api(`/pulls/${number}`), repository, expected);
}

// A manual dispatch or an old red rerun is never authority to repair a green
// or currently running head. This is evidence of CI failure, not a diagnosis
// that the cause is a source defect rather than infrastructure or credentials.
function currentFailure(api, repository, expected) {
  const workflow = api('/actions/workflows/ci.yml');
  if (!Number.isSafeInteger(workflow.id) || workflow.path !== '.github/workflows/ci.yml' ||
      workflow.name !== 'CI') throw new Error('Trusted CI workflow identity unavailable');
  const runs = [];
  let complete = false;
  for (let page = 1; page <= 5; page++) {
    const response = api(`/actions/workflows/ci.yml/runs?head_sha=${expected}&per_page=100&page=${page}`);
    if (!Array.isArray(response.workflow_runs) || !Number.isSafeInteger(response.total_count)) {
      throw new Error('Current CI run coverage unavailable');
    }
    runs.push(...response.workflow_runs);
    if (response.workflow_runs.length < 100 && runs.length >= response.total_count) { complete = true; break; }
  }
  if (!complete) throw new Error('Current CI run coverage incomplete');
  if (runs.some(run => run.head_sha !== expected || run.workflow_id !== workflow.id ||
      run.head_repository?.full_name !== repository || !Number.isSafeInteger(run.id) ||
      !Number.isSafeInteger(run.run_attempt))) throw new Error('Untrusted or stale CI run metadata');
  // The list endpoint replaces previous attempts. Their missing outcomes cannot
  // establish an all-failure history, so reruns require active diagnosis too.
  if (runs.some(run => run.run_attempt !== 1)) throw new Error('Prior CI attempt outcomes are unobserved; repair blocked');
  // Conservative source-repair policy: any successful or nonterminal CI run on
  // the same source SHA indicates flaky/infrastructure diagnosis, not authority
  // for autonomous source edits. All observed attempts must be terminal failure.
  if (runs.some(run => run.status !== 'completed' || run.conclusion !== 'failure' ||
      !['pull_request', 'workflow_dispatch'].includes(run.event))) {
    throw new Error('Exact-head CI history requires human or active diagnosis; repair blocked');
  }
  runs.sort((a, b) => b.id - a.id || b.run_attempt - a.run_attempt);
  const latest = runs[0];
  if (!latest || !['pull_request', 'workflow_dispatch'].includes(latest.event) ||
      latest.status !== 'completed' || latest.conclusion !== 'failure') {
    throw new Error('No current completed exact-head CI failure; repair blocked');
  }
  return { failureRun: latest.id, failureAttempt: latest.run_attempt, diagnosis: 'required' };
}

function repairCandidate(api, repository, number, expected) {
  const candidate = inspect(api, repository, number, expected);
  return { ...candidate, ...currentFailure(api, repository, expected) };
}

function comments(api, number) {
  const all = [];
  for (let page = 1; page <= 10; page++) {
    const values = api(`/issues/${number}/comments?per_page=100&page=${page}`);
    all.push(...values);
    if (values.length < 100) return all;
  }
  throw new Error('Attempt history incomplete');
}

function claim(api, repository, number, expected, run) {
  const current = repairCandidate(api, repository, number, expected);
  if (attempted(comments(api, number), expected)) return { ...current, state: 'deduplicated' };
  api(`/issues/${number}/comments`, 'POST', {
    body: `${MARKER}${expected} -->\nRepair attempt claimed by trusted worker run ${run}. This is not a successful repair or verification claim.`
  });
  return { ...current, state: 'claimed' };
}

function publish({ api, repository, number, expected, directory }) {
  validateChanges(directory, expected);
  const current = repairCandidate(api, repository, number, expected);
  const git = (...args) => command('git', args, { cwd: directory });
  command('git', ['check-ref-format', `refs/heads/${current.branch}`]);
  const remote = git('ls-remote', 'origin', `refs/heads/${current.branch}`).trim().split(/\s+/)[0];
  if (remote !== expected) throw new Error('Remote branch changed before publication');
  git('add', '--all');
  git('-c', 'core.hooksPath=/dev/null', '-c', 'user.name=github-actions[bot]',
    '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
    'commit', '-m', 'fix(ci): repair trusted current-head failure');
  repairCandidate(api, repository, number, expected);
  git('push', `--force-with-lease=refs/heads/${current.branch}:${expected}`, 'origin', `HEAD:refs/heads/${current.branch}`);
  const sha = git('rev-parse', 'HEAD').trim();
  inspect(api, repository, number, sha);
  return { ...current, sha, state: 'published_verification_pending' };
}

async function dispatchVerification(api, repository, number, sha,
  { attempts = 10, wait = () => new Promise(resolve => setTimeout(resolve, 1000)) } = {}) {
  if (!Number.isInteger(attempts) || attempts < 1 || attempts > 10) throw new Error('Invalid observation bound');
  const current = inspect(api, repository, number, sha);
  const evidence = [];
  for (const workflow of ['ci.yml', 'codeql.yml']) {
    const endpoint = `/actions/workflows/${workflow}/runs?event=workflow_dispatch&branch=${encodeURIComponent(current.branch)}&per_page=100`;
    const before = new Set(api(endpoint).workflow_runs.map(run => run.id));
    api(`/actions/workflows/${workflow}/dispatches`, 'POST', { ref: current.branch });
    let observed;
    for (let attempt = 0; attempt < attempts; attempt++) {
      inspect(api, repository, number, sha);
      observed = api(endpoint).workflow_runs.find(run => !before.has(run.id) && run.head_sha === sha && run.event === 'workflow_dispatch');
      if (observed) break;
      if (attempt + 1 < attempts) await wait();
    }
    evidence.push({ workflow, run: observed?.id || null, sha, state: observed ? 'pending' : 'verification_blocked' });
  }
  return evidence;
}

async function main() {
  const [operation, number, expected, directory] = process.argv.slice(2);
  const repository = process.env.GITHUB_REPOSITORY;
  const api = client(repository);
  let result;
  if (operation === 'readiness') {
    result = { state: readiness({ credentials: process.env.REPAIR_CREDENTIALS_AVAILABLE === 'true',
      writers: process.env.REPAIR_WRITERS_ENABLED === 'true' }) };
  } else if (operation === 'inspect') result = inspect(api, repository, number, expected);
  else if (operation === 'failure') result = repairCandidate(api, repository, number, expected);
  else if (operation === 'claim') result = claim(api, repository, number, expected, process.env.GITHUB_RUN_ID);
  else if (operation === 'validate-changes') { validateChanges(directory, expected); result = { state: 'validated' }; }
  else if (operation === 'publish') result = publish({ api, repository, number, expected, directory });
  else if (operation === 'verify') result = { verification: await dispatchVerification(api, repository, number, expected) };
  else throw new Error('Unknown repair operation');
  console.log(JSON.stringify(result));
  if (result.verification?.some(item => item.state === 'verification_blocked')) process.exitCode = 1;
  if (process.env.GITHUB_OUTPUT) {
    for (const [key, value] of Object.entries(result)) {
      if (typeof value === 'string' || typeof value === 'number') fs.appendFileSync(process.env.GITHUB_OUTPUT, `${key}=${value}\n`);
    }
  }
}

module.exports = { validate, readiness, attempted, protectedPath, validateChanges, inspect, currentFailure, repairCandidate, claim, publish, dispatchVerification };
if (require.main === module) main().catch(error => { console.error(error.message); process.exitCode = 1; });
