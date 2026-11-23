import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { verifyMergeIdentity, assertValidationResults, inspectMergedSource, REQUIRED_VALIDATIONS, PUBLICATION_VALIDATIONS } from './post_merge_validation.mjs';
import { SCOPED, ALWAYS } from './post_merge_scope.mjs';

const repo = 'pietro1704/Epub-to-Mp3';
// Follow-up workflows every master validation run (push or dispatch) starts itself; the
// publishers have no workflow_run trigger.
const FOLLOW_UPS = { 'release-followup': ['validated', ['validated'], ['auto-release.yml', 'release-pr.yml']],
  'publication-followup': ['publication', ['publication', 'validated'], ['sync-hf.yml']] };
const sha = 'a'.repeat(40);
function fixture() {
  return { repo, sha, master: sha, event: 'push', ref: 'refs/heads/master', comparison: { status: 'identical', ahead_by: 0 },
    pulls: [{ number: 887, state: 'closed', merged_at: '2026-10-20T16:34:11Z', merge_commit_sha: sha,
      base: { ref: 'master', repo: { full_name: repo } } }] };
}

test('exact confirmed merge and an older reachable merge may be validated', () => {
  assert.equal(verifyMergeIdentity(fixture()).sha, sha);
  const f = fixture(); f.master = 'b'.repeat(40); f.comparison.status = 'behind';
  assert.equal(verifyMergeIdentity(f).master, f.master);
});

test('PR heads, unmerged changes and wrong repository or merge identities fail closed', () => {
  for (const patch of [{ event: 'pull_request' }, { ref: 'refs/heads/feature/example' }, { sha: 'invalid' }, { pulls: [] },
    { comparison: { status: 'diverged', ahead_by: 1 } }, { comparison: { status: 'behind', ahead_by: '0' } }]) {
    assert.throws(() => verifyMergeIdentity({ ...fixture(), ...patch }));
  }
  for (const patch of [{ state: 'open' }, { merged_at: null }, { merge_commit_sha: 'b'.repeat(40) },
    { base: { ref: 'develop', repo: { full_name: repo } } }, { base: { ref: 'master', repo: { full_name: 'other/repo' } } }]) {
    const f = fixture(); Object.assign(f.pulls[0], patch); assert.throws(() => verifyMergeIdentity(f));
  }
});

const everything = () => Object.fromEntries(Object.keys(SCOPED).map(name => [name, true]));
function results(selection = everything()) {
  const needs = Object.fromEntries(REQUIRED_VALIDATIONS.map(name => [name, { result: 'success' }]));
  needs.scope = { result: 'success', outputs: { selection: JSON.stringify(selection) } };
  return needs;
}

test('every required validation must complete successfully before publication', () => {
  const needs = results();
  assert.equal(assertValidationResults(needs), true);
  for (const result of ['failure', 'cancelled', 'skipped', 'in_progress', undefined]) {
    assert.throws(() => assertValidationResults({ ...needs, codeql: { result } }));
    assert.throws(() => assertValidationResults({ ...needs, faber: { result } }), 'A selected scoped job must pass');
  }
  for (const value of [undefined, [], {}, { ci: { result: 'success' } }]) assert.throws(() => assertValidationResults(value));
  for (const name of REQUIRED_VALIDATIONS) {
    const incomplete = { ...needs }; delete incomplete[name];
    assert.throws(() => assertValidationResults(incomplete), /Missing required validation/);
  }
});

test('only a job the scope did not select may be skipped, and a selection must be complete', () => {
  const selection = { ...everything(), flutter: false, linux: false };
  const needs = results(selection);
  for (const name of ['flutter', 'linux']) needs[name] = { result: 'skipped' };
  assert.equal(assertValidationResults(needs), true);
  assert.throws(() => assertValidationResults({ ...needs, faber: { result: 'skipped' } }), /faber/);
  assert.throws(() => assertValidationResults({ ...needs, flutter: { result: 'failure' } }), /flutter/, 'A job that ran must pass');
  for (const always of ['ci', 'codeql', 'native', 'audit', 'ruby', 'merge']) {
    assert.throws(() => assertValidationResults({ ...needs, [always]: { result: 'skipped' } }), new RegExp(always));
  }
  for (const outputs of [undefined, {}, { selection: 'not json' }, { selection: '[]' },
    { selection: JSON.stringify({ ...selection, codeql: false }) }, { selection: JSON.stringify({ faber: true }) },
    { selection: JSON.stringify({ ...selection, faber: 'false' }) }]) {
    assert.throws(() => assertValidationResults({ ...needs, scope: { result: 'success', outputs } }));
  }
  assert.throws(() => assertValidationResults({ ...needs, scope: { result: 'failure', outputs: needs.scope.outputs } }), /scope/);
});

test('read-only inspection rejects incomplete pages and propagates unavailable metadata', () => {
  const f = fixture(); const calls = [];
  const invoke = args => {
    calls.push(args);
    if (args.at(-1).includes('/git/ref/')) return { object: { sha } };
    if (args.at(-1).includes('/compare/')) return f.comparison;
    return [f.pulls];
  };
  assert.equal(inspectMergedSource({ ...f, invoke }).pull, 887);
  assert.equal(calls.length, 3);
  assert.ok(calls.every(args => args[0] === 'api' && !args.includes('--method')));
  for (const pages of [{}, [], [Array(100).fill(f.pulls[0])], [null]]) {
    assert.throws(() => inspectMergedSource({ ...f, invoke: args => args.at(-1).includes('/pulls?') ? pages : invoke(args) }));
  }
  assert.throws(() => inspectMergedSource({ ...f, invoke: () => { throw new Error('Unavailable'); } }), /Unavailable/);
});

let workflowCache;
function workflows() {
  if (workflowCache) return workflowCache;
  const result = spawnSync('ruby', ['-ryaml', '-rjson', '-e',
    'puts JSON.generate(Dir.glob("*.yml").to_h { |file| [file, YAML.safe_load(File.read(file), aliases: false)] })'],
  { cwd: new URL('../.github/workflows/', import.meta.url), encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  workflowCache = JSON.parse(result.stdout);
  return workflowCache;
}

function workflow(file) {
  const parsed = workflows()[file];
  assert.ok(parsed, `Missing workflow: ${file}`);
  return parsed;
}

function isPinnedWorkflowReference(reference) {
  return typeof reference === 'string' && (reference.startsWith('./') || /^[\w.-]+(?:\/[\w.-]+)+@[0-9a-f]{40}$/.test(reference));
}

test('every workflow action reference is local or pinned to a full SHA', () => {
  assert.equal(isPinnedWorkflowReference('./.github/workflows/reusable.yml'), true);
  assert.equal(isPinnedWorkflowReference('actions/checkout@' + 'a'.repeat(40)), true);
  for (const reference of ['actions/checkout@v4', 'actions/checkout@' + 'a'.repeat(39),
    'actions/checkout@' + 'a'.repeat(40) + 'g', 'actions@checkout@' + 'a'.repeat(40),
    'actions/checkout@' + 'A'.repeat(40), 'actions/checkout@' + 'a'.repeat(40) + ' # v4']) {
    assert.equal(isPinnedWorkflowReference(reference), false, reference);
  }

  const files = readdirSync(new URL('../.github/workflows/', import.meta.url)).filter(file => file.endsWith('.yml'));
  assert.ok(files.length > 0, 'workflow inventory must not be empty');
  const references = [];
  for (const file of files) {
    const jobs = workflow(file).jobs ?? {};
    for (const [jobName, job] of Object.entries(jobs)) {
      if (job.uses) references.push({ file, location: `jobs.${jobName}.uses`, value: job.uses });
      for (const [index, step] of (job.steps ?? []).entries()) {
        if (step.uses) references.push({ file, location: `jobs.${jobName}.steps[${index}].uses`, value: step.uses });
      }
    }
  }
  assert.ok(references.length > 0, 'workflow reference inventory must not be empty');
  for (const reference of references) {
    assert.ok(isPinnedWorkflowReference(reference.value), `${reference.file}:${reference.location}: ${reference.value}`);
  }
});

test('postmerge finishes active CodeQL validation while keeping a single pending source', () => {
  const post = workflow('post-merge-validation.yml');
  const codeql = workflow('codeql.yml');
  assert.equal(post.concurrency.group, 'post-merge-${{ github.ref }}');
  assert.equal(post.concurrency['cancel-in-progress'], false);
  assert.equal(post.concurrency.queue ?? 'single', 'single');
  assert.equal(codeql.concurrency['cancel-in-progress'], false);
  assert.notEqual(post.concurrency.group, codeql.concurrency.group);
  assert.equal(post.jobs.codeql.needs, 'merge');
  for (const name of ['merge', 'validated']) {
    assert.equal(post.jobs[name].steps[0].with.ref, '${{ github.sha }}');
  }
  for (const job of Object.values(codeql.jobs)) {
    const analyze = job.steps?.find(step => (step.uses ?? '').startsWith('github/codeql-action/analyze@'));
    if (!analyze) continue;
    assert.match(analyze.uses, /^github\/codeql-action\/analyze@[0-9a-f]{40}(?:\s+#.*)?$/);
    assert.ok(job['timeout-minutes'] > 0 && job['timeout-minutes'] <= 90);
  }
});

test('postmerge graph contains every runtime and aggregates all called workflows', () => {
  const post = workflow('post-merge-validation.yml');
  const events = post.on ?? post.true;
  assert.equal(events.push, undefined, 'validation is batched by post-merge-batch.yml, not started per push');
  assert.ok(events.workflow_dispatch);
  assert.equal(events.pull_request, undefined);
  const required = Object.keys(post.jobs).filter(name => !['validated', 'publication', ...Object.keys(FOLLOW_UPS)].includes(name)).sort();
  assert.deepEqual(required, [...REQUIRED_VALIDATIONS].sort());
  assert.deepEqual([...post.jobs.validated.needs].sort(), required);
  assert.equal(post.jobs.validated.if, 'always()');
  assert.equal(post.jobs.ci.with.full_validation, true);
  for (const job of Object.values(post.jobs)) {
    if (!job.uses) continue;
    const called = workflow(job.uses.replace('./.github/workflows/', ''));
    assert.ok(Object.hasOwn(called.on ?? called.true, 'workflow_call'), job.uses);
  }
  const finalScript = post.jobs.validated.steps.map(step => step.run ?? '').join('\n');
  assert.match(finalScript, /assertValidationResults/);
  assert.match(finalScript, /post_merge_validation\.mjs/);
});

test('the Rails image regression runs for the integrated SHA before validation succeeds', () => {
  const post = workflow('post-merge-validation.yml');
  const job = post.jobs['rails-image'];
  assert.deepEqual(job?.needs, ['merge', 'scope']);
  assert.equal(job.uses, './.github/workflows/rails-image-regression.yml');
  assert.ok(post.jobs.validated.needs.includes('rails-image'));
  const image = workflow('rails-image-regression.yml').jobs.image;
  const checkout = image.steps.find(step => step.uses?.startsWith('actions/checkout@'));
  assert.equal(checkout.with.ref, '${{ github.sha }}');
  assert.equal(checkout.with['persist-credentials'], false);
  assert.ok(image.steps.some(step => step.run === 'ruby_app/rails_gateway/bin/image-regression'));
});

test('postmerge runs every always-on job and gates each scoped job on its scope output', () => {
  const post = workflow('post-merge-validation.yml');
  assert.deepEqual([...ALWAYS, ...Object.keys(SCOPED)].sort(), [...REQUIRED_VALIDATIONS].sort());
  for (const name of ALWAYS) assert.equal(post.jobs[name].if, undefined, `${name} must always run`);
  for (const name of Object.keys(SCOPED)) {
    assert.deepEqual(post.jobs[name].needs, ['merge', 'scope'], name);
    assert.equal(post.jobs[name].if, `fromJSON(needs.scope.outputs.selection)['${name}']`, name);
  }
  assert.deepEqual(post.jobs.scope.outputs, { selection: '${{ steps.scope.outputs.selection }}' });
  const checkout = post.jobs.scope.steps[0];
  assert.equal(checkout.with.ref, '${{ github.sha }}');
  assert.equal(checkout.with['fetch-depth'], 0);
  assert.equal(post.jobs.scope.steps.at(-1).run, 'node scripts/post_merge_scope.mjs');
});

test('the publication aggregate requires exactly the surfaces the Space needs, with the same skip rule', () => {
  const post = workflow('post-merge-validation.yml');
  const job = post.jobs.publication;
  assert.equal(job.name, 'Publication surfaces validated');
  assert.equal(job.if, 'always()');
  assert.deepEqual([...job.needs].sort(), [...PUBLICATION_VALIDATIONS].sort());
  assert.deepEqual([...PUBLICATION_VALIDATIONS].sort(), ['audit', 'browser', 'ci', 'codeql', 'merge', 'rails-image', 'ruby', 'scope', 'snapshot']);
  assert.equal(job.steps[0].with.ref, '${{ github.sha }}');
  const script = job.steps.map(step => step.run ?? '').join('\n');
  assert.match(script, /assertValidationResults\(JSON\.parse\(process\.env\.NEEDS_JSON\), PUBLICATION_VALIDATIONS\)/);
  // Every publication surface is also part of the full validation.
  for (const name of PUBLICATION_VALIDATIONS) assert.ok(REQUIRED_VALIDATIONS.includes(name), name);
  // The real-model browser conversion runs once, as its own scoped job.
  assert.equal(post.jobs.browser.uses, './.github/workflows/rails-real-model.yml');
  assert.equal(post.jobs.faber.with.browser_runtime, false);
  const faber = workflow('faber-integration.yml');
  assert.equal((faber.on ?? faber.true).workflow_call.inputs.browser_runtime.default, true);
  assert.match(faber.jobs['rails-browser-runtime'].if, /inputs\.browser_runtime != false/);

  const subset = Object.fromEntries(PUBLICATION_VALIDATIONS.map(name => [name, { result: 'success' }]));
  subset.scope = { result: 'success', outputs: { selection: JSON.stringify(Object.fromEntries(Object.keys(SCOPED).map(name => [name, true]))) } };
  assert.equal(assertValidationResults(subset, PUBLICATION_VALIDATIONS), true);
  for (const name of PUBLICATION_VALIDATIONS.filter(name => name !== 'scope')) {
    assert.throws(() => assertValidationResults({ ...subset, [name]: { result: 'failure' } }, PUBLICATION_VALIDATIONS), new RegExp(name));
    const missing = { ...subset }; delete missing[name];
    assert.throws(() => assertValidationResults(missing, PUBLICATION_VALIDATIONS), /Missing required validation/);
  }
  assert.throws(() => assertValidationResults({ ...subset, 'rails-image': { result: 'skipped' } }, PUBLICATION_VALIDATIONS), /rails-image/,
    'A selected publication surface may not be skipped');
});

test('every master validation run starts its follow-up workflows, which wait for it', () => {
  const post = workflow('post-merge-validation.yml');
  const dispatched = "github.ref == 'refs/heads/master'";
  for (const [name, [gate, needs, files]] of Object.entries(FOLLOW_UPS)) {
    const job = post.jobs[name];
    assert.ok(job, name);
    // Every follow-up waits for `validated`, the last aggregate, so the run completes right after it.
    assert.deepEqual([job.needs].flat(), needs, name);
    assert.match(job.if, new RegExp(`^always\\(\\) && needs\\.${gate}\\.result == 'success' && `), name);
    assert.ok(job.if.endsWith(dispatched), name);
    assert.deepEqual(job.permissions, { actions: 'write' }, name);
    const step = job.steps.at(-1);
    assert.equal(step.env.VALIDATION_RUN, '${{ github.run_id }}');
    assert.equal(step.env.GH_TOKEN, '${{ github.token }}');
    // A superseded commit starts nothing: the newer validation owns the publication.
    assert.match(step.run, /current="\$\(gh api "repos\/\$GITHUB_REPOSITORY\/git\/ref\/heads\/master" --jq \.object\.sha\)"\n\s*if \[ "\$current" != "\$GITHUB_SHA" \]; then/, name);
    assert.ok(step.run.indexOf('GITHUB_SHA') < step.run.indexOf('gh workflow run'), name);
    for (const file of files) {
      assert.ok(step.run.includes(`gh workflow run ${file} --repo "$GITHUB_REPOSITORY" --ref master -f validation_run="$VALIDATION_RUN"`), file);
      const called = workflow(file);
      assert.equal((called.on ?? called.true).workflow_dispatch.inputs.validation_run.required, false, file);
      const [gateJob] = Object.values(called.jobs).filter(candidate => candidate.steps?.some(s => s.id === 'validated'));
      const index = gateJob.steps.findIndex(s => s.name === 'Wait for the dispatching validation to complete');
      assert.ok(index >= 0 && index < gateJob.steps.findIndex(s => s.id === 'validated'), `${file} waits before its gate`);
      const wait = gateJob.steps[index];
      assert.equal(wait.if, "inputs.validation_run != ''", file);
      assert.equal(wait.env.VALIDATION_RUN, '${{ inputs.validation_run }}', file);
      assert.match(wait.run, /wait_for_validation\.mjs" --repo "\$GITHUB_REPOSITORY" --run "\$VALIDATION_RUN"$/, file);
    }
  }
  for (const file of ['auto-release.yml', 'release-pr.yml', 'sync-hf.yml']) {
    assert.equal((workflow(file).on ?? workflow(file).true).workflow_run, undefined, `${file} must not also start from workflow_run`);
  }
});
