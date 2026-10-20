#!/usr/bin/env node
// Workflow-owned code reads GitHub metadata; it never checks out or executes PR code.
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { assertPrGatePolicy } from './pr_gate_policy.mjs';
const SHA = /^[0-9a-f]{40}$/;
const ensure = (condition, message) => { if (!condition) throw new Error(message); };

function ownRun(check, repo, runId) {
  if (!/^\d+$/.test(runId ?? '') || check.__typename !== 'CheckRun') return false;
  try {
    const url = new URL(check.detailsUrl);
    return url.origin === 'https://github.com' && (url.pathname === `/${repo}/actions/runs/${runId}`
      || url.pathname.startsWith(`/${repo}/actions/runs/${runId}/`));
  } catch { return false; }
}
export function evaluate({ pr, runs, comparison, repo, head }) {
  if (!pr || pr.state !== 'OPEN' || pr.isDraft !== false || pr.baseRefName !== 'master'
      || pr.headRefOid !== head || pr.isCrossRepository !== false
      || pr.reviewDecision === 'CHANGES_REQUESTED' || pr.mergeable !== 'MERGEABLE'
      || !['CLEAN', 'UNSTABLE'].includes(pr.mergeStateStatus)) return { eligible: false, reason: 'pr_state_or_head' };
  if (!comparison || comparison.behind_by !== 0 || !['ahead', 'identical'].includes(comparison.status))
    return { eligible: false, reason: 'base_not_current' };
  if (!Array.isArray(pr.statusCheckRollup)) return { eligible: false, reason: 'missing_checks' };
  // Only the scoped PR workflow blocks integration. Full runtime/security
  // validation belongs to the merged SHA and gates publishers separately.
  const completedRun = (workflowRuns) => {
    if (!Array.isArray(workflowRuns) || workflowRuns.length === 0) return null;
    if (workflowRuns.some(run => !run || run.head_sha !== head || !Number.isSafeInteger(run.id) || run.id <= 0)) return null;
    const latest = workflowRuns.reduce((a, b) => a.id > b.id ? a : b);
    return latest.status === 'completed' && latest.conclusion === 'success' ? latest.id : null;
  };
  const ciRun = completedRun(runs);
  if (!ciRun) return { eligible: false, reason: 'ci_not_successful' };
  const checks = pr.statusCheckRollup.filter(check => check.name === 'PR gate' && ownRun(check, repo, String(ciRun)));
  if (checks.length !== 1 || checks[0].status !== 'COMPLETED' || checks[0].conclusion !== 'SUCCESS')
    return { eligible: false, reason: 'pr_gate_not_successful' };
  return { eligible: true, head, checks: checks.length, ci_run: ciRun };
}
function invokeGh(args) {
  const result = spawnSync('gh', args, { encoding: 'utf8', timeout: 20000, maxBuffer: 8 * 1024 * 1024 });
  ensure(!result.error && !result.signal && result.status === 0, 'GitHub operation failed; no retry or fallback merge');
  return result.stdout;
}
export function guardedMerge({ repo, pr, head, runId, merge = false, invoke = invokeGh }) {
  ensure(typeof repo === 'string' && /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo), 'Invalid repository');
  ensure(typeof pr === 'string' && /^[1-9]\d*$/.test(pr), 'Invalid PR number');
  ensure(typeof head === 'string' && SHA.test(head), 'Invalid expected head SHA');
  ensure(typeof merge === 'boolean', 'Invalid merge mode');
  const fields = 'state,isDraft,baseRefName,headRefOid,isCrossRepository,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup';
  const capture = () => {
    const current = JSON.parse(invoke(['pr', 'view', pr, '--repo', repo, '--json', fields]));
    const workflowRuns = (filename) => {
      const pages = JSON.parse(invoke(['api', '--paginate', '--slurp',
        `repos/${repo}/actions/workflows/${filename}/runs?head_sha=${head}&per_page=100`]));
      ensure(Array.isArray(pages) && pages.every(page => page && Array.isArray(page.workflow_runs)), 'Invalid workflow run response');
      return pages.flatMap(page => page.workflow_runs);
    };
    const comparison = JSON.parse(invoke(['api', `repos/${repo}/compare/master...${head}`]));
    return evaluate({ pr: current, runs: workflowRuns('ci.yml'), comparison, repo, head });
  };
  const first = capture();
  if (!first.eligible || !merge) return { ...first, merged: false };
  const verifyProtection = () => assertPrGatePolicy(JSON.parse(invoke(['api', `repos/${repo}/branches/master/protection`])));
  verifyProtection();
  // Re-read immediately before mutation. GitHub also checks the expected head
  // atomically; a pushed replacement cannot inherit this authorization.
  const final = capture();
  if (!final.eligible) return { ...final, merged: false };
  verifyProtection();
  invoke(['pr', 'merge', pr, '--repo', repo, '--squash', '--match-head-commit', head]);
  // An accepted merge command may enqueue under a server merge queue. Its exit
  // code does not prove the PR has merged; the caller must inspect delivery.
  return { ...final, merged: false, merge_requested: true };
}
export function main(argv = process.argv.slice(2)) {
  const { values, positionals } = parseArgs({ args: argv, options: {
    repo: { type: 'string' }, pr: { type: 'string' }, head: { type: 'string' }, merge: { type: 'boolean', default: false },
  }, strict: true, allowPositionals: false });
  ensure(positionals.length === 0, 'Unexpected arguments');
  const result = guardedMerge({ repo: values.repo, pr: values.pr, head: values.head,
    merge: values.merge, runId: process.env.GITHUB_RUN_ID });
  console.log(JSON.stringify(result));
  if (!result.eligible) process.exitCode = 1;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch { console.error('Merge blocked: invalid invocation or unverifiable GitHub metadata.'); process.exitCode = 1; }
}
