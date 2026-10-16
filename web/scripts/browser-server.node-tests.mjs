import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:net";
import { mkdtemp, mkdir, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startBrowserServer } from "./browser-server.mjs";

const listen = server => new Promise((accept, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", () => accept(server.address().port));
});
const close = server => new Promise(accept => server.close(accept));
async function freePort() {
  const server = createServer();
  const port = await listen(server);
  await close(server);
  return port;
}
async function ownedDescendantPid(root) {
  const value = await readFile(join(root, "descendant.pid"), "utf8");
  if (!/^[1-9][0-9]*$/.test(value)) throw new Error("Inconclusive fixture PID receipt");
  const pid = Number(value);
  if (!Number.isSafeInteger(pid) || pid <= 1 || pid === process.pid) {
    throw new Error("Unsafe fixture PID receipt");
  }
  return pid;
}
async function fakeMise(mode, operation) {
  const root = await mkdtemp(join(tmpdir(), "browser-server-owned-"));
  const original = { PATH: process.env.PATH, BROWSER_SERVER_FIXTURE_ROOT: process.env.BROWSER_SERVER_FIXTURE_ROOT, BROWSER_SERVER_FIXTURE_MODE: process.env.BROWSER_SERVER_FIXTURE_MODE };
  await mkdir(join(root, "web"));
  const childSource = `
    const fs = require('node:fs');
    const pidPath = process.env.BROWSER_SERVER_FIXTURE_ROOT + '/descendant.pid';
    fs.writeFileSync(pidPath + '.tmp', String(process.pid));
    fs.renameSync(pidPath + '.tmp', pidPath);
    if (process.env.BROWSER_SERVER_FIXTURE_MODE === 'failure') {
      setInterval(() => {}, 1000);
      process.send('started');
    } else {
      const http = require('node:http');
      const server = http.createServer((_, response) => response.end('owned fixture'));
      server.listen(Number(process.argv[1]), '127.0.0.1', () => process.send('started'));
    }
  `;
  const wrapper = `#!${process.execPath}
    const { spawn } = require('node:child_process');
    const args = process.argv.slice(2);
    const port = args[args.indexOf('--port') + 1];
    const child = spawn(process.execPath, ['-e', ${JSON.stringify(childSource)}, port], { stdio: ['ignore', 'inherit', 'inherit', 'ipc'] });
    process.on('SIGTERM', () => { child.once('exit', () => process.exit(0)); });
    child.on('message', () => {
      if (process.env.BROWSER_SERVER_FIXTURE_MODE === 'failure') process.exit(17);
    });
    child.on('exit', () => process.exit(0));
  `;
  await writeFile(join(root, "mise"), wrapper, { mode: 0o755 });
  process.env.PATH = `${root}:${original.PATH}`;
  process.env.BROWSER_SERVER_FIXTURE_ROOT = root;
  process.env.BROWSER_SERVER_FIXTURE_MODE = mode;
  try { await operation(root); }
  finally {
    // Only fixture-owned descendants may be killed if an assertion fails.
    try {
      try { process.kill(await ownedDescendantPid(root), "SIGKILL"); }
      catch (error) { if (!["ENOENT", "ESRCH"].includes(error.code)) throw error; }
    } finally {
      for (const [key, value] of Object.entries(original)) {
        if (value === undefined) delete process.env[key]; else process.env[key] = value;
      }
      await rm(root, { recursive: true, force: true });
    }
  }
}
async function assertDescendantExited(root) {
  const pid = await ownedDescendantPid(root);
  assert.throws(() => process.kill(pid, 0), { code: "ESRCH" });
}

test("occupied port is rejected without terminating its unrelated listener", async () => {
  const unrelated = createServer(socket => socket.end());
  const port = await listen(unrelated);
  try {
    await assert.rejects(startBrowserServer({ root: tmpdir(), port }), { code: "EADDRINUSE" });
    assert.equal(unrelated.listening, true);
    // Its port remains owned by the original listener after rejection.
    await assert.rejects(startBrowserServer({ root: tmpdir(), port }), { code: "EADDRINUSE" });
  } finally { await close(unrelated); }
});

test("stop waits for the owned wrapper and server descendant to exit", async () => {
  await fakeMise("ready", async root => {
    const server = await startBrowserServer({ root, port: await freePort() });
    try { assert.equal(await (await fetch(server.origin)).text(), "owned fixture"); }
    finally { await server.stop(); }
    await assertDescendantExited(root);
  });
});

test("startup failure cleans the owned descendant before rejecting", async () => {
  await fakeMise("failure", async root => {
    await assert.rejects(startBrowserServer({ root, port: await freePort() }), /exited before readiness: 17/);
    await assertDescendantExited(root);
  });
});
