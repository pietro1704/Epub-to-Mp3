import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import test from 'node:test';

const require = createRequire(import.meta.url);
const fromPlugin = createRequire(require.resolve('eslint-plugin-react-hooks'));
const { z } = fromPlugin('zod');

test("ESLint's Zod preserves valid arrays and rejects non-array input", () => {
  const schema = z.array(z.string()).max(2);
  assert.deepEqual(schema.parse(['reader', 'player']), ['reader', 'player']);
  assert.equal(schema.safeParse('reader').success, false);
});

test('oversized constrained arrays fail before element or collection refinements', () => {
  // GHSA-mrhx-c7xc-m3w5: an upper bound must gate expensive element parsing.
  let elementsParsed = 0;
  let collectionsRefined = 0;
  const schema = z
    .array(
      z.string().refine(() => {
        elementsParsed += 1;
        return true;
      }),
    )
    .max(2)
    .refine(() => {
      collectionsRefined += 1;
      return true;
    });

  const result = schema.safeParse(['reader', 'player', 'library']);
  assert.equal(result.success, false);
  assert.deepEqual(
    result.error.issues.map((issue) => issue.code),
    ['too_big'],
  );
  assert.equal(elementsParsed, 0);
  assert.equal(collectionsRefined, 0);
});
