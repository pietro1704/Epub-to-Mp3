#!/usr/bin/env node
// Execute this helper only from a trusted default-branch checkout.
//
// A merge made by the merge workflow uses GITHUB_TOKEN, so that workflow dispatches
// Post-merge validation itself, and GitHub creates no workflow_run event when such a
// run completes. The validation run then dispatches its follow-up workflows (Auto
// Release, Release Pull Request, Hugging Face sync) with its own run id; they wait
// here until that run is completed and then apply validated_merge.mjs unchanged.
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { githubApi } from './validated_merge.mjs';

const requireThat = (value, message) => { if (!value) throw new Error(message); };
const VALIDATION_PATH = '.github/workflows/post-merge-validation.yml';

export async function waitForValidation({ repo, runId, api, sleep, attempts = 30, intervalMs = 10000 }) {
  requireThat(/^[\w.-]+\/[\w.-]+$/.test(repo ?? ''), 'Invalid repository');
  requireThat(typeof runId === 'string' && /^[1-9][0-9]{0,18}$/.test(runId), 'Invalid validation run');
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const run = await api(`/repos/${repo}/actions/runs/${runId}`);
    requireThat(run?.path === VALIDATION_PATH && run.head_branch === 'master' && run.repository?.full_name === repo,
      'Run is not a master post-merge validation of this repository');
    if (run.status === 'completed') return run;
    if (attempt < attempts) await sleep(intervalMs);
  }
  throw new Error(`Validation run ${runId} did not complete in time`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const { values } = parseArgs({ options: { repo: { type: 'string' }, run: { type: 'string' } } });
    const run = await waitForValidation({ repo: values.repo, runId: values.run, api: async path => githubApi(path),
      sleep: ms => new Promise(resolve => setTimeout(resolve, ms)) });
    console.log(`Validation run ${run.id} completed: ${run.conclusion}`);
  } catch (error) { console.error(`Follow-up blocked: ${error.message}`); process.exitCode = 1; }
}
