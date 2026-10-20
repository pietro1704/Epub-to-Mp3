import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ensure = (condition, message) => { if (!condition) throw new Error(message); };
const SHA = /^[a-f0-9]{40}$/;
export const REQUIRED_VALIDATIONS = Object.freeze([
  'merge', 'ci', 'codeql', 'ffi', 'faber', 'flutter', 'fallback', 'native',
  'snapshot', 'cli', 'linux', 'isolation', 'offline', 'audit', 'ruby',
]);

export function verifyMergeIdentity({ repo, sha, event, ref, master, comparison, pulls }) {
  ensure(typeof repo === 'string' && /^[\w.-]+\/[\w.-]+$/.test(repo), 'Invalid repository');
  ensure(typeof sha === 'string' && SHA.test(sha), 'Invalid source SHA');
  ensure(['push', 'workflow_dispatch'].includes(event) && ref === 'refs/heads/master', 'Only integrated master can be validated');
  ensure(typeof master === 'string' && SHA.test(master), 'Invalid current master');
  ensure(comparison && comparison.ahead_by === 0 && ['identical', 'behind'].includes(comparison.status), 'Source is no longer reachable from master');
  ensure(Array.isArray(pulls), 'Missing merge evidence');
  const merged = pulls.filter(pr => pr && pr.state === 'closed' && typeof pr.merged_at === 'string' && pr.merged_at.length > 0 &&
    pr.base?.ref === 'master' && pr.base.repo?.full_name === repo && pr.merge_commit_sha === sha && Number.isSafeInteger(pr.number) && pr.number > 0);
  ensure(merged.length > 0, 'No confirmed PR merge for this exact source');
  return { sha, master, pull: merged[0].number };
}

export function assertValidationResults(needs) {
  ensure(needs && typeof needs === 'object' && !Array.isArray(needs), 'Missing validation results');
  ensure(REQUIRED_VALIDATIONS.every(name => Object.hasOwn(needs, name)), 'Missing required validation');
  for (const [name, job] of Object.entries(needs)) {
    ensure(job && job.result === 'success', `Required validation did not succeed: ${name}`);
  }
  return true;
}

function invokeGh(args) {
  const result = spawnSync('gh', args, { encoding: 'utf8', timeout: 20000, maxBuffer: 8 * 1024 * 1024 });
  ensure(!result.error && !result.signal && result.status === 0, 'Cannot verify merge metadata');
  return JSON.parse(result.stdout);
}

export function inspectMergedSource({ repo, sha, event, ref, invoke = invokeGh }) {
  ensure(typeof repo === 'string' && /^[\w.-]+\/[\w.-]+$/.test(repo) && typeof sha === 'string' && SHA.test(sha), 'Invalid source identity');
  ensure(['push', 'workflow_dispatch'].includes(event) && ref === 'refs/heads/master', 'Only integrated master can be validated');
  const master = invoke(['api', `repos/${repo}/git/ref/heads/master`])?.object?.sha;
  const comparison = invoke(['api', `repos/${repo}/compare/master...${sha}`]);
  const pages = invoke(['api', '--paginate', '--slurp', `repos/${repo}/commits/${sha}/pulls?per_page=100`]);
  ensure(Array.isArray(pages) && pages.length > 0 && pages.length <= 20 && pages.every(page => Array.isArray(page) && page.length <= 100) && pages.at(-1).length < 100,
    'Incomplete or unbounded merge history');
  return verifyMergeIdentity({ repo, sha, event, ref, master, comparison, pulls: pages.flat() });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = inspectMergedSource({ repo: process.env.GITHUB_REPOSITORY, sha: process.env.GITHUB_SHA,
      event: process.env.GITHUB_EVENT_NAME, ref: process.env.GITHUB_REF });
    console.log(JSON.stringify(result));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
