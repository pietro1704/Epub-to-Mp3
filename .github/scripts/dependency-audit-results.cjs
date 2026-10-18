#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { parseArgs } = require('node:util');

function consolidate(directory) {
  const findings = [];
  for (const name of ['cargo-audit.json', 'pip-audit.json', 'npm-audit.json']) {
    const filename = path.join(directory, name);
    if (!fs.existsSync(filename)) throw new Error(`Missing required scanner report: ${name}`);
    let data;
    try {
      data = JSON.parse(fs.readFileSync(filename, 'utf8'));
    } catch {
      throw new Error(`Invalid scanner JSON: ${name}`);
    }
    if (name === 'npm-audit.json' && (data.metadata?.vulnerabilities?.total ?? 0) === 0) continue;
    if (name === 'pip-audit.json') {
      const dependencies = Array.isArray(data) ? data : (data.dependencies ?? []);
      if (!dependencies.some(item => item && typeof item === 'object' && item.vulns?.length)) continue;
    }
    if (name === 'cargo-audit.json' && !data.vulnerabilities?.list?.length) continue;
    findings.push({ source: name, data });
  }
  return findings;
}

function main(argv = process.argv.slice(2)) {
  const { values } = parseArgs({ args: argv, options: { directory: { type: 'string' } }, strict: true });
  if (!values.directory) throw new Error('A report directory is required');
  const findings = consolidate(values.directory);
  const serialized = JSON.stringify(findings);
  fs.writeFileSync(path.join(values.directory, 'vulnerability-findings.json'), serialized);
  console.log(`findings=${serialized}`);
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

module.exports = { consolidate, main };
