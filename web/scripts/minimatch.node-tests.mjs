import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const require = createRequire(import.meta.url);
const consumers = ['eslint', '@eslint/config-array', '@typescript-eslint/typescript-estree'];

for (const consumer of consumers) {
  const fromConsumer = createRequire(require.resolve(consumer));
  const { Minimatch, minimatch } = fromConsumer('minimatch');

  test(`${consumer} preserves recursive, negative and dot-file matching`, () => {
    for (const [path, pattern, options, expected] of [
      ['src/reader/book.ts', 'src/**/*.ts', {}, true],
      ['src/reader/book.js', 'src/**/*.ts', {}, false],
      ['src/reader.test.ts', '**/!(*.test).ts', {}, false],
      ['src/reader.ts', '**/!(*.test).ts', {}, true],
      ['.cache/book.ts', '**/*.ts', {}, false],
      ['.cache/book.ts', '**/*.ts', { dot: true }, true],
    ]) {
      assert.equal(minimatch(path, pattern, options), expected);
      assert.equal(new Minimatch(pattern, options).match(path), expected);
    }
  });

  test(`${consumer} bounds globstar parent expansion`, () => {
    // GHSA-g3hv-75wg-m249: optimization must honor the expansion budget too.
    const budget = 4;
    const matcher = new Minimatch('**/../a/**/../b/**/../c/**/../d/*.ts', {
      optimizationLevel: 2,
      braceExpandMax: budget,
    });
    assert.ok(matcher.globParts.length <= budget);
  });
}

test("Capacitor's Glob/Rimraf chain preserves discovery and removal scope", async () => {
  const fromCapacitor = createRequire(require.resolve('@capacitor/cli/package.json'));
  const fromRimraf = createRequire(fromCapacitor.resolve('rimraf'));
  const { glob } = fromRimraf('glob');
  const { rimraf } = fromCapacitor('rimraf');
  const root = await realpath(await mkdtemp(join(tmpdir(), 'epub-glob-security-')));
  const fixture = join(root, 'fixture');

  try {
    await mkdir(join(fixture, 'remove', 'nested'), { recursive: true });
    await writeFile(join(fixture, 'remove', 'nested', 'disposable.tmp'), 'temporary');
    await writeFile(join(fixture, 'remove', 'keep.txt'), 'retained');
    await writeFile(join(root, 'outside.txt'), 'outside');

    assert.deepEqual(await glob('remove/**/*.tmp', { cwd: fixture }), [
      'remove/nested/disposable.tmp',
    ]);
    await rimraf('remove/**/*.tmp', { glob: { cwd: fixture } });
    assert.deepEqual(await glob('remove/**/*.tmp', { cwd: fixture }), []);
    assert.equal(await readFile(join(fixture, 'remove', 'keep.txt'), 'utf8'), 'retained');
    assert.equal(await readFile(join(root, 'outside.txt'), 'utf8'), 'outside');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
