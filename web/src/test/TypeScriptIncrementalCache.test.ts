// @vitest-environment node
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { expect, it } from 'vitest';

it('separates incremental caches and rejects changed source despite a warm cache', () => {
  const fixtureRoot = realpathSync(mkdtempSync(join(tmpdir(), 'epub-ts-cache-')));
  const compiler = fileURLToPath(new URL('../../node_modules/typescript/bin/tsc', import.meta.url));
  const compileFixture = (project: string, expectedStatus: number) => {
    const result = spawnSync(
      process.execPath,
      [compiler, '--pretty', 'false', '--project', project],
      { cwd: fixtureRoot, encoding: 'utf8', timeout: 20_000 },
    );
    const diagnostics = result.stdout + result.stderr;
    expect(result.error, diagnostics).toBeUndefined();
    expect(result.status, diagnostics).toBe(expectedStatus);
    return diagnostics;
  };
  try {
    for (const project of ['tsconfig.json', 'tsconfig.build.json']) {
      copyFileSync(
        fileURLToPath(new URL(`../../${project}`, import.meta.url)),
        join(fixtureRoot, project),
      );
    }
    mkdirSync(join(fixtureRoot, 'src'));
    const source = join(fixtureRoot, 'src/main.ts');
    const testSource = join(fixtureRoot, 'src/main.test.ts');
    const validSource = 'export const value: number = 100;\n';
    writeFileSync(source, validSource);
    writeFileSync(testSource, 'const testValue: number = "invalid";\n');

    compileFixture('tsconfig.build.json', 0);
    const buildCache = join(fixtureRoot, 'node_modules/.cache/typescript/build.tsbuildinfo');
    const checkCache = join(fixtureRoot, 'node_modules/.cache/typescript/check.tsbuildinfo');
    expect(existsSync(buildCache)).toBe(true);
    expect(existsSync(checkCache)).toBe(false);
    const initialBuildCacheMtime = statSync(buildCache).mtimeMs;

    expect(compileFixture('tsconfig.json', 2)).toContain('TS2322');
    expect(existsSync(checkCache)).toBe(true);
    writeFileSync(testSource, 'const testValue: number = 123;\n');
    compileFixture('tsconfig.json', 0);
    compileFixture('tsconfig.build.json', 0);
    expect(statSync(buildCache).mtimeMs).toBe(initialBuildCacheMtime);

    // Same-length edits must invalidate cached diagnostics by source identity.
    const invalidSource = 'export const value: number = "x";\n';
    expect(invalidSource.length).toBe(validSource.length);
    writeFileSync(source, invalidSource);
    expect(compileFixture('tsconfig.build.json', 2)).toContain('TS2322');
    writeFileSync(source, validSource);
    compileFixture('tsconfig.build.json', 0);
    // Interrupted metadata publication must recover on the next invocation.
    writeFileSync(buildCache, '{');
    compileFixture('tsconfig.build.json', 0);
    expect(statSync(buildCache).size).toBeGreaterThan(1);
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
}, 120_000);
