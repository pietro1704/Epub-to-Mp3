#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { parseArgs } = require('node:util');

function readReport(directory, name) {
  const filename = path.join(directory, name);
  if (!fs.existsSync(filename)) throw new Error(`Missing required scanner report: ${name}`);
  try {
    return JSON.parse(fs.readFileSync(filename, 'utf8'));
  } catch {
    throw new Error(`Invalid scanner JSON: ${name}`);
  }
}

function commandFailure(command, status) {
  const error = new Error(`Unsuccessful scanner command: ${command}`);
  error.exitCode = status === 130 || status === 143 ? status : 1;
  throw error;
}

function readStatuses(directory) {
  const statuses = readReport(directory, 'scanner-statuses.json');
  const commands = ['cargoInstall', 'cargoAudit', 'pipInstall', 'pipAudit', 'npmAudit'];
  if (!statuses || Array.isArray(statuses) || typeof statuses !== 'object'
      || Object.keys(statuses).length !== commands.length
      || commands.some(command => !Number.isSafeInteger(statuses[command]) || statuses[command] < 0)) {
    throw new Error('Invalid scanner schema: scanner-statuses.json');
  }
  for (const command of commands) {
    const status = statuses[command];
    if (command.endsWith('Install') ? status !== 0 : status !== 0 && status !== 1) {
      commandFailure(command, status);
    }
  }
  return statuses;
}

function consolidate(directory) {
  const statuses = readStatuses(directory);
  const findings = [];
  for (const name of ['cargo-audit.json', 'pip-audit.json', 'npm-audit.json']) {
    const data = readReport(directory, name);
    if (data && typeof data === 'object' && Object.hasOwn(data, 'error')) {
      throw new Error(`Scanner reported an error: ${name}`);
    }
    if (name === 'npm-audit.json') {
      const total = data?.metadata?.vulnerabilities?.total;
      if (!Number.isSafeInteger(total) || total < 0) throw new Error(`Invalid scanner schema: ${name}`);
      const counts = data.metadata.vulnerabilities;
      const levels = ['info', 'low', 'moderate', 'high', 'critical'];
      if (levels.some(level => !Number.isSafeInteger(counts[level]) || counts[level] < 0)
          || levels.reduce((sum, level) => sum + counts[level], 0) !== total) {
        throw new Error(`Invalid scanner schema: ${name}`);
      }
      const exceedsThreshold = counts.moderate > 0 || counts.high > 0 || counts.critical > 0;
      if (statuses.npmAudit !== Number(exceedsThreshold)) commandFailure('npmAudit', statuses.npmAudit);
      if (total === 0) continue;
    }
    if (name === 'pip-audit.json') {
      const dependencies = Array.isArray(data) ? data : (data.dependencies ?? []);
      if (dependencies.some(item => item && typeof item === 'object' && Object.hasOwn(item, 'skip_reason'))) {
        throw new Error(`Incomplete scanner report: ${name}`);
      }
      const found = dependencies.some(item => item && typeof item === 'object' && item.vulns?.length);
      if (statuses.pipAudit !== Number(found)) commandFailure('pipAudit', statuses.pipAudit);
      if (!found) continue;
    }
    if (name === 'cargo-audit.json') {
      const vulnerabilities = data?.vulnerabilities;
      if (!vulnerabilities || typeof vulnerabilities !== 'object' || Array.isArray(vulnerabilities)
          || typeof vulnerabilities.found !== 'boolean'
          || !Number.isSafeInteger(vulnerabilities.count) || vulnerabilities.count < 0
          || !Array.isArray(vulnerabilities.list) || vulnerabilities.count !== vulnerabilities.list.length
          || vulnerabilities.found !== (vulnerabilities.count > 0)) {
        throw new Error(`Invalid scanner schema: ${name}`);
      }
      const found = vulnerabilities.found;
      if (statuses.cargoAudit !== Number(found)) commandFailure('cargoAudit', statuses.cargoAudit);
      if (!found) continue;
    }
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
    process.exitCode = error.exitCode === 130 || error.exitCode === 143 ? error.exitCode : 1;
  }
}

module.exports = { consolidate, main };
