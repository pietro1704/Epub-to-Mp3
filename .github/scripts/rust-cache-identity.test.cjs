const { test } = require('node:test');
const assert = require('node:assert/strict');
const { identity } = require('./rust-cache-identity.cjs');

const compiler = (tool, args) => `${tool} ${args.join(' ')} fixture-v1`;

test('identical effective configuration reuses the identity regardless of environment order or run', () => {
  assert.equal(identity({ RUSTFLAGS: '-C debuginfo=1', CARGO_BUILD_JOBS: '1', GITHUB_RUN_ID: '1' }, compiler),
    identity({ GITHUB_RUN_ID: '2', CARGO_BUILD_JOBS: '1', RUSTFLAGS: '-C debuginfo=1' }, compiler));
});

test('compiler, Cargo, native flags and runtime configuration invalidate the identity', () => {
  const original = identity({}, compiler);
  for (const key of ['RUSTFLAGS', 'RUSTC', 'CARGO_ENCODED_RUSTFLAGS', 'CARGO_BUILD_TARGET',
    'CC_aarch64_apple_ios', 'CFLAGS', 'CXXFLAGS', 'LDFLAGS', 'CMAKE_TOOLCHAIN_FILE', 'SDKROOT', 'DEVELOPER_DIR',
    'MACOSX_DEPLOYMENT_TARGET', 'IPHONEOS_DEPLOYMENT_TARGET', 'ORT_LIB_LOCATION', 'DOCS_RS']) {
    assert.notEqual(identity({ [key]: 'changed' }, compiler), original, key);
  }
  for (const changed of ['rustc', 'cargo']) {
    assert.notEqual(identity({}, (tool, args) => compiler(tool, args) + (args.includes(changed) ? ' v2' : '')), original);
  }
});

test('Apple cache identity includes Xcode and every compiled platform SDK', () => {
  const environment = { RUNNER_OS: 'macOS' };
  const original = identity(environment, (tool, args) => {
    assert.equal(tool, 'mise');
    assert.deepEqual(args.slice(0, 2), ['exec', '--']);
    return compiler(tool, args);
  });
  for (const changed of ['xcodebuild', 'macosx', 'iphoneos', 'iphonesimulator']) {
    assert.notEqual(identity(environment, (tool, args) =>
      compiler(tool, args) + (tool === changed || args.includes(changed) ? ' v2' : '')), original, changed);
  }
});

test('failed or cancelled identity commands stop cache lookup instead of returning a partial identity', () => {
  for (const signal of ['failure', 'SIGTERM']) {
    const error = new Error(signal);
    assert.throws(() => identity({}, () => { throw error; }), candidate => candidate === error);
  }
});
