#!/usr/bin/env node
// Execute this helper only from a trusted default-branch checkout.
import { spawnSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
const SHA = /^[a-f0-9]{40}$/;
const requireThat = (value, message) => { if (!value) throw new Error(message); };
export async function validatedMerge({ repo, ref, tag, latest = false, api }) {
  requireThat(/^[\w.-]+\/[\w.-]+$/.test(repo ?? ''), 'Invalid repository');
  requireThat(typeof ref === 'string' && ref.length > 0 && !ref.startsWith('-'), 'Invalid source');
  const read = (path) => api(`/repos/${repo}${path}`);
  const pages = async (path, field) => {
    const result = [];
    for (let page = 1; page <= 100; page++) {
      const response = await read(`${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`);
      const items = field ? response[field] : response;
      requireThat(Array.isArray(items), 'Incomplete metadata');
      result.push(...items);
      if (field) requireThat(Number.isSafeInteger(response.total_count) && response.total_count >= 0, 'Missing run count');
      if (items.length < 100) {
        if (field) requireThat(result.length === response.total_count, 'Incomplete run history');
        return result;
      }
    }
    throw new Error('Metadata pagination exceeded');
  };
  const source = await read(`/commits/${encodeURIComponent(ref)}`);
  const sha = source.sha;
  requireThat(SHA.test(sha ?? ''), 'Invalid resolved SHA');
  if (SHA.test(ref)) requireThat(sha === ref, 'Source identity changed');
  if (tag) {
    requireThat(/^v\d+\.\d+\.\d+(?:[-+][\w.-]+)?$/.test(tag), 'Invalid release tag');
    requireThat((await read(`/commits/${encodeURIComponent(tag)}`)).sha === sha, 'Tag differs from validated source');
  }
  const workflow = await read('/actions/workflows/post-merge-validation.yml');
  requireThat(Number.isSafeInteger(workflow.id) && workflow.id > 0 && workflow.path === '.github/workflows/post-merge-validation.yml'
    && workflow.name === 'Post-merge validation' && workflow.state === 'active', 'Untrusted validation workflow');
  const runs = await pages(`/actions/workflows/${workflow.id}/runs?head_sha=${sha}`, 'workflow_runs');
  const trusted = run => run && run.workflow_id === workflow.id && run.head_sha === sha && run.event === 'push'
    && run.head_branch === 'master' && run.repository?.full_name === repo && run.head_repository?.full_name === repo
    && Number.isSafeInteger(run.id) && run.id > 0 && Number.isSafeInteger(run.run_attempt) && run.run_attempt > 0;
  const candidates = runs.filter(trusted);
  requireThat(candidates.length > 0, 'No trusted post-merge validation');
  const selected = candidates.reduce((a, b) => a.id > b.id ? a : b);
  const run = await read(`/actions/runs/${selected.id}`);
  requireThat(trusted(run) && run.id === selected.id && run.run_attempt === selected.run_attempt
    && run.status === 'completed' && run.conclusion === 'success', 'Latest validation is unsuccessful or stale');
  const prs = await pages(`/commits/${sha}/pulls`);
  requireThat(prs.some(pr => pr.merged_at && pr.state === 'closed' && pr.merge_commit_sha === sha
    && pr.base?.ref === 'master' && pr.base?.repo?.full_name === repo), 'Source is not a confirmed master merge');
  const master = (await read('/git/ref/heads/master')).object?.sha;
  requireThat(SHA.test(master ?? ''), 'Missing current master');
  const comparison = await read(`/compare/${sha}...${master}`);
  requireThat(comparison.behind_by === 0 && ['ahead', 'identical'].includes(comparison.status), 'Source is not reachable on current master');
  requireThat(!latest || master === sha, 'Source is superseded on master');
  // Detect identity changes during the metadata checks, immediately before returning authorization.
  const currentRun = await read(`/actions/runs/${run.id}`);
  requireThat(trusted(currentRun) && currentRun.id === run.id && currentRun.run_attempt === run.run_attempt
    && currentRun.status === 'completed' && currentRun.conclusion === 'success', 'Validation changed during publication checks');
  if (tag) requireThat((await read(`/commits/${encodeURIComponent(tag)}`)).sha === sha, 'Tag changed during publication checks');
  if (latest) requireThat((await read('/git/ref/heads/master')).object?.sha === sha, 'Master advanced during publication checks');
  return { sha, master, run_id: run.id, run_attempt: run.run_attempt };
}
export function githubApi(path) {
  const result = spawnSync('gh', ['api', path], { encoding: 'utf8', timeout: 30000, maxBuffer: 16 * 1024 * 1024 });
  requireThat(!result.error && result.status === 0, 'GitHub metadata unavailable');
  return JSON.parse(result.stdout);
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const { values } = parseArgs({ options: { repo: { type: 'string' }, ref: { type: 'string' }, tag: { type: 'string' }, latest: { type: 'boolean', default: false } } });
    const result = await validatedMerge({ ...values, api: githubApi });
    if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `sha=${result.sha}\n`);
    console.log(JSON.stringify(result));
  } catch (error) { console.error(`Publication blocked: ${error.message}`); process.exitCode = 1; }
}
