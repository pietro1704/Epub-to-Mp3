#!/usr/bin/env node
// Strict branch protection requires an up-to-date base, so a green PR that falls
// behind master can never satisfy the guarded merge. This helper refreshes one
// eligible PR at a time; the guarded merge still re-verifies its new head.
// Workflow-owned code reads GitHub metadata; it never checks out or executes PR code.
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
const SHA = /^[0-9a-f]{40}$/;
const ensure = (condition, message) => { if (!condition) throw new Error(message); };

const gateOf = (pr) => (Array.isArray(pr.statusCheckRollup) ? pr.statusCheckRollup : [])
  .filter(check => check?.name === 'PR gate');

// A PR is in flight when it is current with master and its PR gate has not
// finished. Refreshing another PR then would only multiply CI reruns.
export function select(prs) {
  ensure(Array.isArray(prs), 'Invalid pull request list');
  const ready = prs.filter(pr => pr && pr.isDraft === false && pr.baseRefName === 'master');
  const inFlight = ready.find(pr => !['BEHIND', 'DIRTY'].includes(pr.mergeStateStatus)
    && gateOf(pr).some(check => check.status !== 'COMPLETED'));
  if (inFlight) return { refresh: null, reason: 'pr_in_flight', pr: inFlight.number };
  const candidates = ready.filter(pr => pr.mergeStateStatus === 'BEHIND'
    && pr.isCrossRepository === false
    && pr.reviewDecision !== 'CHANGES_REQUESTED'
    && typeof pr.headRefOid === 'string' && SHA.test(pr.headRefOid)
    // A failed gate needs a fix, not a rebase; a new push resets it.
    && !gateOf(pr).some(check => check.status === 'COMPLETED' && check.conclusion !== 'SUCCESS'))
    .sort((a, b) => a.number - b.number);
  if (candidates.length === 0) return { refresh: null, reason: 'no_candidate' };
  const pr = candidates[0];
  return { refresh: pr.number, head: pr.headRefOid };
}

function invokeGh(args) {
  const { PR_BRANCH_UPDATE_TOKEN, ...environment } = process.env;
  // Updates pushed with GITHUB_TOKEN do not trigger CI. Confine the user
  // credential to the update-branch call so the refreshed head gets checks.
  const update = args[0] === 'api' && args.includes('PUT')
    && /^repos\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pulls\/[1-9]\d*\/update-branch$/.test(args.at(-1) ?? '');
  if (update && PR_BRANCH_UPDATE_TOKEN) environment.GH_TOKEN = PR_BRANCH_UPDATE_TOKEN;
  const result = spawnSync('gh', args, { env: environment, encoding: 'utf8', timeout: 20000, maxBuffer: 8 * 1024 * 1024 });
  if (result.error || result.signal || result.status !== 0) throw new Error('GitHub operation failed');
  return result.stdout;
}

export function refresh({ repo, invoke = invokeGh }) {
  ensure(typeof repo === 'string' && /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo), 'Invalid repository');
  const fields = 'number,isDraft,baseRefName,headRefOid,isCrossRepository,reviewDecision,mergeStateStatus,statusCheckRollup';
  const prs = JSON.parse(invoke(['pr', 'list', '--repo', repo, '--state', 'open', '--base', 'master',
    '--limit', '1000', '--json', fields]));
  const choice = select(prs);
  if (!choice.refresh) return choice;
  invoke(['api', '-X', 'PUT', '-f', `expected_head_sha=${choice.head}`,
    `repos/${repo}/pulls/${choice.refresh}/update-branch`]);
  return { ...choice, update_requested: true };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { repo: { type: 'string' } }, strict: true });
    console.log(JSON.stringify(refresh({ repo: values.repo })));
  } catch {
    console.error('Branch refresh skipped: invalid invocation or GitHub operation failed.');
    process.exitCode = 2;
  }
}
