const { createHash } = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { appendFileSync } = require('node:fs');

function identity(environment = process.env, run = execFileSync) {
  const command = (tool, args) => run(tool, args, { encoding: 'utf8' }).trim();
  const inputs = {
    compiler: command('mise', ['exec', '--', 'rustc', '-vV']),
    cargo: command('mise', ['exec', '--', 'cargo', '-V']),
    environment: Object.keys(environment).sort()
      .filter(key => /^(RUST|CARGO_|CC($|_)|CXX($|_)|CFLAGS|CXXFLAGS|LDFLAGS|CMAKE_|SDKROOT$|DEVELOPER_DIR$|MACOSX_DEPLOYMENT_TARGET$|IPHONEOS_DEPLOYMENT_TARGET$|DOCS_RS$|ORT_)/.test(key))
      .map(key => [key, environment[key]]),
  };
  if (environment.RUNNER_OS === 'macOS') {
    inputs.xcode = command('mise', ['exec', '--', 'xcodebuild', '-version']);
    inputs.sdks = ['macosx', 'iphoneos', 'iphonesimulator'].map(sdk =>
      [sdk, command('mise', ['exec', '--', 'xcrun', '--sdk', sdk, '--show-sdk-version'])]);
  }
  return createHash('sha256').update(JSON.stringify(inputs)).digest('hex');
}

if (require.main === module) {
  appendFileSync(process.env.GITHUB_OUTPUT, `identity=${identity()}\n`);
}

module.exports = { identity };
