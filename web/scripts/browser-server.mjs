import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

/** Own one frontend and its descendants; never attach to an existing listener. */
export async function startBrowserServer({ root, production = false, port }) {
  await new Promise((accept, reject) => {
    const probe = createServer();
    probe.once("error", reject);
    probe.listen({ host: "127.0.0.1", port, exclusive: true }, () => probe.close(accept));
  });
  const origin = `http://127.0.0.1:${port}`;
  const processGroup = process.platform !== "win32";
  const child = spawn("mise", ["exec", "--", "npm", "run", production ? "preview" : "dev", "--", "--host", "127.0.0.1", "--port", String(port), "--strictPort"], {
    cwd: resolve(root, "web"), stdio: "inherit", detached: processGroup,
  });
  let spawnError;
  child.once("error", error => { spawnError = error; });
  const signal = value => {
    if (!child.pid) return;
    try {
      if (processGroup) process.kill(-child.pid, value);
      else child.kill(value);
    } catch (error) { if (error.code !== "ESRCH") throw error; }
  };
  const stop = async () => {
    signal("SIGTERM");
    if (child.exitCode === null && child.signalCode === null && child.pid) {
      await Promise.race([new Promise(accept => child.once("exit", accept)), delay(5000)]);
    }
    signal("SIGKILL");
    const deadline = Date.now() + 2000;
    for (;;) {
      let alive = false;
      try {
        if (child.pid) {
          process.kill(processGroup ? -child.pid : child.pid, 0);
          alive = true;
        }
      } catch (error) { if (error.code !== "ESRCH") throw error; }
      if (!alive) return;
      if (Date.now() >= deadline) throw new Error("Owned browser server process group did not exit");
      await delay(25);
    }
  };
  try {
    for (let attempt = 0; attempt <= 100; attempt++) {
      if (spawnError) throw spawnError;
      if (child.exitCode !== null || child.signalCode !== null) {
        throw new Error(`Browser frontend exited before readiness: ${child.exitCode ?? child.signalCode}`);
      }
      try {
        const response = await fetch(origin, { signal: AbortSignal.timeout(1000) });
        if (response.ok) return { origin, stop };
      } catch { /* Await only this frontend after confirming the port was free. */ }
      await delay(200);
    }
    throw new Error("Owned browser frontend did not become ready");
  } catch (error) {
    await stop();
    throw error;
  }
}
