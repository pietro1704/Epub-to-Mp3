import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { env } from "node:process";
import { describe, expect, it } from "vitest";
import { buildCliReproduction } from "../utils/cliReproduction";
import type { ConversionFormValues, TtsPreferences } from "../types/conversion";

// The GitHub Ubuntu image supplies both shells. Never launch fixtures on the user's host.
describe.runIf(env.GITHUB_ACTIONS === "true" && env.RUNNER_OS === "Linux")("CLI recipe shell argument boundaries", () => {
  it.each(["bash", "pwsh"])("preserves source and JSON literally through %s", shell => {
    const directory = mkdtempSync(join(tmpdir(), "cli-reproduction-"));
    try {
      const record = join(directory, "arguments.json");
      writeFileSync(join(directory, "converter-cli"), [
        "#!/usr/bin/env node",
        "const fs = require('node:fs');",
        "fs.writeFileSync(process.env.CLI_ARGUMENTS, JSON.stringify(process.argv.slice(2)));",
      ].join("\n") + "\n", { mode: 0o700 });
      const source = shell === "bash"
        ? join(directory, "Jane's $(touch marker) & livro.epub")
        : "C:\\Books\\Jane's $(New-Item marker) & livro.epub";
      if (shell === "bash") writeFileSync(source, "fixture");
      const preferences: TtsPreferences = {
        policy_version: 2,
        primary: { engine: "edge", model_id: null, voice: "pt-BR-Jane's \"voz\" \\á $(echo unexpected)" },
        secondary: { engine: "piper", model_id: "pt_BR-faber-medium", voice: null },
        allow_online_fallback: false,
      };
      const request: ConversionFormValues = {
        file: null, localPath: source, engine: "edge", footnoteMode: "inline",
        tts_preferences: preferences, chapters: "1-2", noParallel: true,
      };
      const recipe = buildCliReproduction(request);
      expect(recipe?.shell).toBe(shell === "bash" ? "Bash/Zsh" : "PowerShell");
      const command = recipe?.command;
      expect(command).toBeDefined();
      if (!command) throw new Error("Expected a representable recipe");
      const args = shell === "bash"
        ? ["--noprofile", "--norc", "-c", command]
        : ["-NoProfile", "-NonInteractive", "-Command", command];
      execFileSync(shell, args, {
        cwd: directory,
        env: { ...env, PATH: directory + delimiter + env.PATH, CLI_ARGUMENTS: record },
        timeout: 10000,
        stdio: "pipe",
      });
      expect(JSON.parse(readFileSync(record, "utf8"))).toEqual([
        "convert", source, "--tts-preferences-json", JSON.stringify(preferences),
        "--chapter", "position:0", "--chapter", "position:1", "--no-parallel",
      ]);
      expect(existsSync(join(directory, "marker"))).toBe(false);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  }, 15000);
});
