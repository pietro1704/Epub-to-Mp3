import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
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

  test(`${consumer} rejects globstar parent expansion above its budget`, () => {
    // GHSA-g3hv-75wg-m249: optimization must honor the expansion budget too.
    const budget = 4;
    assert.throws(
      () => new Minimatch('**/../a/**/../b/**/../c/**/../d/*.ts', {
        optimizationLevel: 2,
        braceExpandMax: budget,
      }),
      { name: 'RangeError', message: /too many patterns/ },
    );
    assert.equal(minimatch('a/book.ts', '**/a/*.ts', {
      optimizationLevel: 2,
      braceExpandMax: budget,
    }), true);
  });
}
