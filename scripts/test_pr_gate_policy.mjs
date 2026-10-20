import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configurePrGate, assertPrGatePolicy, REQUIRED_CHECKS, initialProtectionBody } from './pr_gate_policy.mjs';
const repo = 'owner/project';
const protection = () => ({ enforce_admins: { enabled: true }, required_conversation_resolution: { enabled: true },
  allow_deletions: { enabled: false }, allow_force_pushes: { enabled: false }, required_pull_request_reviews: { required_approving_review_count: 1 } });
const withGate = value => ({ ...value, required_status_checks: { ...structuredClone(REQUIRED_CHECKS), contexts: ['PR gate'] } });
function client({ initial = protection(), stale = false, denied = false, moved = false, wrongApp = false, failWrite = false, changeBeforePut = false } = {}) {
  const calls = [], inputs = []; let state = structuredClone(initial), reads = 0;
  return { calls, inputs, run(apply = false) { return configurePrGate({ repo, apply, invoke(args, input) {
    calls.push(args); inputs.push(input);
    if (denied) throw Error('Forbidden');
    if (args.at(-1) === 'apps/github-actions') return JSON.stringify({ id: wrongApp ? 7 : 15368, slug: 'github-actions', owner: { login: 'github' } });
    if (args.includes('PATCH') || args.includes('PUT')) {
      if (failWrite) throw Error('Write forbidden');
      if (state.required_status_checks == null) {
        assert.equal(args[2], 'PUT', 'PATCH of absent status checks returns HTTP404 in the real API');
        assert.deepEqual(args, ['api', '--method', 'PUT', `repos/${repo}/branches/master/protection`, '--input', '-']);
        assert.deepEqual(JSON.parse(input), initialProtectionBody(state));
        assert.equal(Object.hasOwn(JSON.parse(input).required_status_checks, 'contexts'), false,
          'GitHub rejects deprecated contexts combined with checks via oneOf');
      } else {
        assert.deepEqual(args, ['api', '--method', 'PATCH', `repos/${repo}/branches/master/protection/required_status_checks`, '--input', '-']);
        assert.deepEqual(JSON.parse(input), REQUIRED_CHECKS);
      }
      if (!stale) state = withGate(state);
      return JSON.stringify(state.required_status_checks);
    }
    assert.deepEqual(args, ['api', `repos/${repo}/branches/master/protection`]);
    reads++;
    const response = structuredClone(state);
    if ((moved && reads > 2) || (changeBeforePut && reads === 2)) response.allow_force_pushes.enabled = true;
    return JSON.stringify(response);
  } }); } };
}
test('explicit apply installs exactly the trusted gate and preserves every other protection', () => {
  const f = client(); assert.deepEqual(f.run(true), { repo, branch: 'master', verified: true, changed: true, context: 'PR gate', app_id: 15368, strict: true });
  assert.equal(f.calls.length, 5);
  assert.equal(f.calls.filter(args => args.includes('PUT')).length, 1);
});
test('matching policy verifies idempotently without any write', () => {
  for (const apply of [false, true]) {
    const f = client({ initial: withGate(protection()) });
    assert.equal(f.run(apply).changed, false);
    assert.equal(f.calls.length, 3);
    assert.equal(f.calls.some(args => args.includes('PATCH')), false);
  }
});
test('existing status-check policy uses a narrow PATCH instead of replacing master protection', () => {
  const f = client({ initial: { ...protection(), required_status_checks: { strict: false, checks: [], contexts: [] } } });
  assert.equal(f.run(true).verified, true);
  assert.equal(f.calls.filter(args => args.includes('PATCH')).length, 1);
  assert.equal(f.calls.filter(args => args.includes('PUT')).length, 0);
});
test('initial PUT preserves reviews, actor restrictions, signatures and every documented boolean', () => {
  const value = { ...protection(), required_signatures: { enabled: true },
    required_pull_request_reviews: { required_approving_review_count: 2, dismiss_stale_reviews: true,
      require_code_owner_reviews: true, require_last_push_approval: true,
      dismissal_restrictions: { users: [{ login: 'reviewer' }], teams: [{ slug: 'reviewers' }], apps: [{ slug: 'review-app' }] },
      bypass_pull_request_allowances: { users: [{ login: 'owner' }], teams: [], apps: [] } },
    restrictions: { users: [{ login: 'maintainer' }], teams: [{ slug: 'core' }], apps: [{ slug: 'release' }] },
    required_linear_history: { enabled: true }, block_creations: { enabled: true }, lock_branch: { enabled: true },
    allow_fork_syncing: { enabled: true } };
  const body = initialProtectionBody(value);
  assert.deepEqual(body.required_status_checks, REQUIRED_CHECKS);
  assert.equal(Object.hasOwn(body.required_status_checks, 'contexts'), false);
  assert.deepEqual(body.restrictions, { users: ['maintainer'], teams: ['core'], apps: ['release'] });
  assert.deepEqual(body.required_pull_request_reviews.dismissal_restrictions, { users: ['reviewer'], teams: ['reviewers'], apps: ['review-app'] });
  assert.equal(body.required_pull_request_reviews.required_approving_review_count, 2);
  assert.equal(body.required_pull_request_reviews.require_last_push_approval, true);
  for (const field of ['enforce_admins', 'required_linear_history', 'block_creations', 'lock_branch', 'allow_fork_syncing', 'required_conversation_resolution']) assert.equal(body[field], true);
  assert.equal(body.allow_force_pushes, false);
  assert.equal(body.allow_deletions, false);
  assert.equal(body.required_signatures, undefined, 'signatures use a separate API and are verified unchanged');
  assert.equal(client({ initial: value }).run(true).verified, true);
});
test('unknown protection fields and concurrent pre-PUT changes fail before any mutation', () => {
  for (const options of [{ initial: { ...protection(), new_future_rule: { enabled: true } } },
    { initial: { ...protection(), required_pull_request_reviews: { required_approving_review_count: 1, unknown_rule: true } } },
    { changeBeforePut: true }]) {
    const f = client(options); assert.throws(() => f.run(true));
    assert.equal(f.calls.some(args => args.includes('PUT') || args.includes('PATCH')), false);
  }
});
test('inspection cannot silently enable absent protection or accept a forged app', () => {
  for (const options of [{}, { wrongApp: true }, { initial: { ...protection(), enforce_admins: { enabled: false } } }]) {
    const f = client(options); assert.throws(() => f.run());
    assert.equal(f.calls.some(args => args.includes('PATCH')), false);
  }
});
test('missing, unbound, extra, stale or non-strict checks reject a merge policy', () => {
  for (const change of [p => delete p.required_status_checks, p => p.required_status_checks.strict = false,
    p => p.required_status_checks.checks[0].app_id = null, p => p.required_status_checks.checks[0].app_id = 1,
    p => p.required_status_checks.checks.push({ context: 'CodeQL', app_id: 15368 }),
    p => p.required_status_checks.contexts.push('CodeQL'), p => p.enforce_admins.enabled = false]) {
    const value = withGate(protection()); change(value); assert.throws(() => assertPrGatePolicy(value));
  }
});
test('permission failures, failed writes and stale readback cannot report success', () => {
  for (const options of [{ denied: true }, { stale: true }, { moved: true }, { wrongApp: true }, { failWrite: true }]) {
    const f = client(options); assert.throws(() => f.run(true));
  }
});
test('real CLI sends structured policy on stdin and verifies server readback', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pr-gate-policy-'));
  try {
    writeFileSync(join(directory, 'state.json'), JSON.stringify(protection()));
    const gh = join(directory, 'gh');
    writeFileSync(gh, `#!${process.execPath}\n` + String.raw`
const fs = require('node:fs');
const args = process.argv.slice(2);
const path = process.env.POLICY_FIXTURE;
fs.appendFileSync(path + '/calls.jsonl', JSON.stringify(args) + '\n');
let state = JSON.parse(fs.readFileSync(path + '/state.json', 'utf8'));
if (args.at(-1) === 'apps/github-actions') {
  process.stdout.write(JSON.stringify({id:15368,slug:'github-actions',owner:{login:'github'}}));
} else if (args.includes('PATCH') || args.includes('PUT')) {
  const input = JSON.parse(fs.readFileSync(0, 'utf8'));
  const policy = args.includes('PUT') ? input.required_status_checks : input;
  if (Object.hasOwn(policy, 'checks') && Object.hasOwn(policy, 'contexts')) {
    console.error('gh: Validation failed (HTTP 422)'); process.exit(1);
  }
  state.required_status_checks = {...policy, contexts:policy.checks.map(check => check.context)};
  fs.writeFileSync(path + '/state.json', JSON.stringify(state));
  process.stdout.write(JSON.stringify(state.required_status_checks));
} else process.stdout.write(JSON.stringify(state));
`);
    chmodSync(gh, 0o700);
    const result = spawnSync(process.execPath, [new URL('./pr_gate_policy.mjs', import.meta.url).pathname,
      '--repo', repo, '--apply'], { encoding: 'utf8', timeout: 15000,
      env: { ...process.env, PATH: `${directory}:${process.env.PATH}`, POLICY_FIXTURE: directory } });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout).verified, true);
    const after = JSON.parse(readFileSync(join(directory, 'state.json'), 'utf8'));
    assertPrGatePolicy(after);
    delete after.required_status_checks;
    assert.deepEqual(after, protection());
    const calls = readFileSync(join(directory, 'calls.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
    assert.equal(calls.length, 5);
    assert.equal(calls.filter(args => args.includes('PUT')).length, 1);
    writeFileSync(gh, `#!${process.execPath}\nconsole.log(JSON.stringify({message:'Validation Failed', errors:[{resource:'ProtectedBranch',field:'required_status_checks',message:'More than one subschema in oneOf matched'}]})); console.error('gh: Validation failed (HTTP 422)'); process.exit(1);\n`);
    const failure = spawnSync(process.execPath, [new URL('./pr_gate_policy.mjs', import.meta.url).pathname,
      '--repo', repo], { encoding: 'utf8', timeout: 15000,
      env: { ...process.env, PATH: `${directory}:${process.env.PATH}` } });
    assert.equal(failure.status, 1);
    assert.match(failure.stderr, /HTTP 422/);
    assert.match(failure.stderr, /More than one subschema in oneOf matched/);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
test('invalid repository and apply values fail before a GitHub operation', () => {
  for (const changed of [{ repo: 'owner/project;evil' }, { repo: ['owner/project'] }, { apply: 'true' }]) {
    assert.throws(() => configurePrGate({ repo, ...changed, invoke: () => assert.fail('must not call GitHub') }));
  }
});
