#!/usr/bin/env node
// Change only required status checks; retain all other master protections.
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual, parseArgs } from 'node:util';
export const ACTIONS_APP_ID = 15368;
export const REQUIRED_CHECKS = { strict: true, checks: [{ context: 'PR gate', app_id: ACTIONS_APP_ID }] };
const ensure = (condition, message) => { if (!condition) throw new Error(message); };
export function assertPrGatePolicy(protection) {
  const policy = protection?.required_status_checks;
  ensure(protection?.enforce_admins?.enabled === true, 'Master protection must apply to administrators');
  ensure(policy?.strict === true && Array.isArray(policy.checks) && policy.checks.length === 1
    && policy.checks[0]?.context === 'PR gate' && policy.checks[0]?.app_id === ACTIONS_APP_ID,
  'Master must require only PR gate from GitHub Actions with an up-to-date base');
  ensure(Array.isArray(policy.contexts) && policy.contexts.length === 1 && policy.contexts[0] === 'PR gate',
    'Required status contexts do not match PR gate');
  return true;
}
export function invokeGh(args, input) {
  const result = spawnSync('gh', args, { input, encoding: 'utf8', timeout: 20000, maxBuffer: 1024 * 1024 });
  const status = result.stderr?.match(/HTTP\s+(\d{3})/)?.[1];
  let detail = '';
  try {
    const response = JSON.parse(result.stdout);
    if (typeof response?.message === 'string') detail = response.message;
    if (Array.isArray(response?.errors)) {
      detail += ' ' + response.errors.map(error => typeof error === 'string' ? error :
        [error?.resource, error?.field, error?.code, error?.message].filter(value => typeof value === 'string').join(': ')).join('; ');
    }
    detail = detail.replace(/[\r\n\x00-\x1f]/g, ' ').slice(0, 512);
  } catch { /* Never expose arbitrary process output or authentication details. */ }
  ensure(!result.error && !result.signal && result.status === 0,
    `Cannot verify GitHub protection${status ? ` (HTTP ${status})` : ''}${detail ? `: ${detail}` : ''}; no merge or fallback`);
  return result.stdout;
}
const BOOLEAN_FIELDS = ['required_linear_history', 'allow_force_pushes', 'allow_deletions', 'block_creations',
  'required_conversation_resolution', 'lock_branch', 'allow_fork_syncing'];
const known = (object, fields) => ensure(object && typeof object === 'object' && !Array.isArray(object)
  && Object.keys(object).every(key => fields.includes(key)), 'Unknown protection fields; inspect before updating');
function actors(value) {
  known(value, ['url', 'users_url', 'teams_url', 'apps_url', 'users', 'teams', 'apps']);
  return Object.fromEntries(['users', 'teams', 'apps'].map(key => {
    const list = value[key] ?? [];
    ensure(Array.isArray(list), 'Invalid protection actor list');
    const names = list.map(actor => actor?.[key === 'users' ? 'login' : 'slug']);
    ensure(names.every(name => typeof name === 'string' && name.length > 0), 'Invalid protection actor identity');
    return [key, names];
  }));
}
function enabled(value) {
  if (value == null) return false;
  known(value, ['url', 'enabled']);
  ensure(typeof value.enabled === 'boolean', 'Invalid protection boolean');
  return value.enabled;
}
// GitHub PATCH cannot create the required-check subresource. For its initial
// creation, translate the documented GET fields into the full PUT schema.
export function initialProtectionBody(value) {
  known(value, ['url', 'required_status_checks', 'enforce_admins', 'required_pull_request_reviews',
    'restrictions', 'required_signatures', ...BOOLEAN_FIELDS]);
  const reviews = value.required_pull_request_reviews;
  let reviewBody = null;
  if (reviews != null) {
    const booleans = ['dismiss_stale_reviews', 'require_code_owner_reviews', 'require_last_push_approval'];
    known(reviews, ['url', 'dismissal_restrictions', 'bypass_pull_request_allowances', 'required_approving_review_count', ...booleans]);
    ensure(Number.isInteger(reviews.required_approving_review_count) && reviews.required_approving_review_count >= 0
      && reviews.required_approving_review_count <= 6, 'Invalid required review count');
    reviewBody = { required_approving_review_count: reviews.required_approving_review_count };
    for (const field of booleans) {
      ensure(reviews[field] == null || typeof reviews[field] === 'boolean', 'Invalid review protection');
      reviewBody[field] = reviews[field] ?? false;
    }
    for (const field of ['dismissal_restrictions', 'bypass_pull_request_allowances']) {
      if (reviews[field] != null) reviewBody[field] = actors(reviews[field]);
    }
  }
  return { required_status_checks: structuredClone(REQUIRED_CHECKS), enforce_admins: enabled(value.enforce_admins),
    required_pull_request_reviews: reviewBody, restrictions: value.restrictions == null ? null : actors(value.restrictions),
    ...Object.fromEntries(BOOLEAN_FIELDS.map(field => [field, enabled(value[field])])) };
}
function unrelatedProtection(value) {
  const body = initialProtectionBody(value);
  delete body.required_status_checks;
  return { ...body, required_signatures: enabled(value.required_signatures) };
}
export function configurePrGate({ repo, apply = false, invoke = invokeGh }) {
  ensure(typeof repo === 'string' && /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo), 'Invalid repository');
  ensure(typeof apply === 'boolean', 'Invalid apply mode');
  const endpoint = `repos/${repo}/branches/master/protection`;
  const read = () => JSON.parse(invoke(['api', endpoint]));
  const before = read();
  const baseline = unrelatedProtection(before);
  // A missing base protection or disabled administrator enforcement is not
  // repaired implicitly: this command owns only the required-check setting.
  ensure(before?.enforce_admins?.enabled === true, 'Existing master protection must apply to administrators');
  const app = JSON.parse(invoke(['api', 'apps/github-actions']));
  ensure(app?.id === ACTIONS_APP_ID && app.slug === 'github-actions' && app.owner?.login === 'github', 'GitHub Actions app identity mismatch');
  let matches = false;
  try { matches = assertPrGatePolicy(before); } catch { /* Explicit apply may repair required checks. */ }
  if (!matches && apply) {
    if (before.required_status_checks == null) {
      const body = initialProtectionBody(before);
      ensure(isDeepStrictEqual(before, read()), 'Master protection changed before initial update; inspect before retrying');
      invoke(['api', '--method', 'PUT', endpoint, '--input', '-'], JSON.stringify(body));
    } else invoke(['api', '--method', 'PATCH', `${endpoint}/required_status_checks`,
      '--input', '-'], JSON.stringify(REQUIRED_CHECKS));
  } else ensure(matches, 'Required PR gate protection is absent or differs; use --apply to configure it');
  const after = read();
  assertPrGatePolicy(after);
  ensure(isDeepStrictEqual(baseline, unrelatedProtection(after)), 'Other master protections changed during configuration; inspect before merging');
  return { repo, branch: 'master', verified: true, changed: !matches, context: 'PR gate', app_id: ACTIONS_APP_ID, strict: true };
}
export function main(argv = process.argv.slice(2)) {
  const { values } = parseArgs({ args: argv, options: { repo: { type: 'string' }, apply: { type: 'boolean', default: false } }, strict: true });
  console.log(JSON.stringify(configurePrGate({ repo: values.repo, apply: values.apply })));
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch (error) { console.error(`PR gate policy: ${error.message}`); process.exitCode = 1; }
}
