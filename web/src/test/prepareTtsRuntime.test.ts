// @vitest-environment node
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
// @ts-expect-error The packaging entrypoint is plain JavaScript.
import { prepareTtsRuntime } from "../../scripts/prepare-tts-runtime.mjs";

const roots: string[] = [];
afterEach(async () => {
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

async function fixture() {
  const root = await mkdtemp(resolve(tmpdir(), "piper-runtime-"));
  roots.push(root);
  await symlink(resolve("node_modules"), resolve(root, "node_modules"), "dir");
  await mkdir(resolve(root, "public/tts"), { recursive: true });
  return root;
}

describe("Piper runtime packaging", () => {
  it("copies the installed CPU module and WASM bytes, removes obsolete runtime files and preserves unrelated assets", async () => {
    const root = await fixture();
    await writeFile(resolve(root, "public/tts/ort-wasm.wasm"), "obsolete");
    await writeFile(resolve(root, "public/tts/keep.txt"), "keep");
    await prepareTtsRuntime(root);
    await prepareTtsRuntime(root);
    for (const name of ["ort-wasm-simd-threaded.mjs", "ort-wasm-simd-threaded.wasm"]) {
      const digest = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
      expect(digest(await readFile(resolve(root, "public/tts", name)))).toBe(
        digest(await readFile(resolve("node_modules/onnxruntime-web/dist", name))),
      );
    }
    expect(await readFile(resolve(root, "public/tts/keep.txt"), "utf8")).toBe("keep");
    await expect(readFile(resolve(root, "public/tts/ort-wasm.wasm"))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("rejects a missing installed runtime instead of reporting packaging success", async () => {
    const root = await mkdtemp(resolve(tmpdir(), "piper-runtime-missing-"));
    roots.push(root);
    await expect(prepareTtsRuntime(root)).rejects.toMatchObject({ code: "ENOENT" });
  });
});
