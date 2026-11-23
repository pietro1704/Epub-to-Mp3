#!/usr/bin/env node
// Execute this helper only from a trusted default-branch checkout.
//
// Post-merge validation takes all five hosted macOS runners plus about fifteen other
// jobs, so running it once per merge starved the pull request gates. This helper runs
// on a schedule and starts ONE validation of the current master head when the head has
// no validation yet, none is running, and no pull request check is waiting (a
// validation older than FORCE_AFTER_MS starts anyway so publication cannot starve).
// It dispatches the unchanged Post-merge validation workflow, so every gate, the
// publishers and validated_merge.mjs behave exactly as before; only the cadence changes.
import { spawnSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SHA = /^[a-f0-9]{40}$/;
export const FORCE_AFTER_MS = 3 * 60 * 60 * 1000;
const ACTIVE = ['queued', 'in_progress', 'pending', 'waiting', 'requested'];
const ensure = (condition, message) => { if (!condition) throw new Error(message); };

// runs: newest-first post-merge runs of master; prCiActive: pull request CI runs queued or running.
export function decideBatch({ head, runs, prCiActive, now = Date.now(), forceAfterMs = FORCE_AFTER_MS }) {
  ensure(SHA.test(head ?? ''), 'Invalid master head');
  ensure(Array.isArray(runs) && Number.isSafeInteger(prCiActive) && prCiActive >= 0, 'Incomplete run history');
  const skip = reason => ({ dispatch: false, reason });
  if (runs.some(run => ACTIVE.includes(run.status))) return skip('a validation is already running or waiting');
  const same = runs.filter(run => run.head_sha === head);
  if (same.some(run => run.conclusion === 'success')) return skip('master head is already validated');
  if (same.some(run => run.conclusion === 'failure')) return skip('master head already failed validation; a new merge or a manual dispatch is needed');
  const newest = runs.map(run => Date.parse(run.created_at)).filter(Number.isFinite).sort((a, b) => b - a)[0];
  if (prCiActive > 0 && newest !== undefined && now - newest < forceAfterMs) return skip(`${prCiActive} pull request CI run(s) active; they go first`);
  return { dispatch: true, reason: prCiActive > 0 ? 'last validation is older than the forced interval' : 'no pull request CI is waiting' };
}

function gh(args) {
  const result = spawnSync('gh', args, { encoding: 'utf8', timeout: 30000, maxBuffer: 16 * 1024 * 1024 });
  ensure(!result.error && result.status === 0, 'GitHub metadata unavailable');
  return result.stdout;
}
const api = path => JSON.parse(gh(['api', path]));

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const repo = process.env.GITHUB_REPOSITORY;
    ensure(/^[\w.-]+\/[\w.-]+$/.test(repo ?? ''), 'Invalid repository');
    const head = api(`/repos/${repo}/git/ref/heads/master`).object?.sha;
    const runs = api(`/repos/${repo}/actions/workflows/post-merge-validation.yml/runs?branch=master&per_page=50`).workflow_runs;
    let prCiActive = 0;
    for (const status of ['queued', 'in_progress']) {
      const response = api(`/repos/${repo}/actions/workflows/ci.yml/runs?event=pull_request&status=${status}&per_page=1`);
      ensure(Number.isSafeInteger(response.total_count), 'Incomplete CI history');
      prCiActive += response.total_count;
    }
    const decision = decideBatch({ head, runs, prCiActive });
    console.log(JSON.stringify({ head, prCiActive, ...decision }));
    const dryRun = process.env.BATCH_DRY_RUN === 'true' || process.env.GITHUB_REF !== 'refs/heads/master';
    if (decision.dispatch && !dryRun) {
      gh(['workflow', 'run', 'post-merge-validation.yml', '--repo', repo, '--ref', 'master', '-f', 'scoped=true']);
      console.log('Dispatched Post-merge validation for the current master head.');
    }
    if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `dispatch=${decision.dispatch}\n`);
  } catch (error) {
    // Never dispatch on doubt: the next scheduled run decides again.
    console.error(`Batch decision failed: ${error.message}`);
    process.exitCode = 1;
  }
}
