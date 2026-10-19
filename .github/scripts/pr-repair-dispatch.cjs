'use strict';

const { spawnSync } = require('node:child_process');
const { repairCandidate } = require('./pr-repair-safety.cjs');

function dispatch({ api, repository, sha, event, writers = false, credentials = false }) {
  if (writers !== true || credentials !== true) return [];
  if (!['pull_request', 'workflow_dispatch'].includes(event)) return [];
  if (!/^[a-f0-9]{40}$/.test(sha)) throw new Error('Invalid run SHA');
  const result = [];
  for (const pr of api(`/commits/${sha}/pulls`)) {
    let candidate;
    try { candidate = repairCandidate(api, repository, pr.number, sha); }
    catch { continue; }
    api('/actions/workflows/pr-autofix-worker.yml/dispatches', 'POST', {
      ref: 'master', inputs: { pr_number: String(candidate.number), head_sha: sha }
    });
    result.push(candidate.number);
  }
  return result;
}

if (require.main === module) {
  const repository = process.env.GITHUB_REPOSITORY;
  const api = (endpoint, method = 'GET', body) => {
    const args = ['api', `/repos/${repository}${endpoint}`, '--method', method];
    if (body !== undefined) args.push('--input', '-');
    const result = spawnSync('gh', args, { encoding: 'utf8', input: body === undefined ? undefined : JSON.stringify(body) });
    if (result.error || result.status !== 0) throw new Error('GitHub metadata or dispatch failed');
    return JSON.parse(result.stdout || 'null');
  };
  console.log(JSON.stringify({ dispatched: dispatch({ api, repository, sha: process.env.RUN_SHA, event: process.env.RUN_EVENT,
    writers: process.env.REPAIR_WRITERS_ENABLED === 'true',
    credentials: process.env.REPAIR_CREDENTIALS_AVAILABLE === 'true' }) }));
}
module.exports = { dispatch };
