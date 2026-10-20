import { describe, expect, it, vi } from "vitest";
import StatusPanel from "../components/StatusPanel";
import DownloadsPanel from "../components/DownloadsPanel";
import { renderWithProviders } from "./testUtils";
import { screen } from "@testing-library/react";
import { buildCliReproduction } from "../utils/cliReproduction";
import { loadTtsPreferences } from "../services/TtsPreferences";
import type { ConversionFormValues, TtsPreferences } from "../types/conversion";

const buildCliCommand = (values: ConversionFormValues) => buildCliReproduction(values)?.command;

const preferences: TtsPreferences = {
  primary: { engine: "piper", model_id: "pt_BR-faber-medium", voice: null },
  secondary: null,
  allow_online_fallback: false,
};
const request: ConversionFormValues = {
  file: null, localPath: "/books/book.epub", engine: "piper",
  footnoteMode: "inline", tts_preferences: preferences,
};

describe("CLI reproduction", () => {
  it("preserves the current default Piper/System recovery policy", () => {
    localStorage.clear();
    const captured = loadTtsPreferences();
    expect(captured.policy_version).toBe(2);
    expect(captured.secondary?.engine).toBe("system");
    expect(buildCliCommand({ ...request, tts_preferences: captured }))
      .toContain("--tts-preferences-json '" + JSON.stringify(captured) + "'");
  });

  it("preserves policy v2 with an explicit no-fallback choice", () => {
    const captured: TtsPreferences = { ...preferences, policy_version: 2 };
    expect(buildCliCommand({ ...request, tts_preferences: captured }))
      .toContain("--tts-preferences-json '" + JSON.stringify(captured) + "'");
  });

  it("supports a valid System primary without inventing a secondary", () => {
    const captured: TtsPreferences = {
      ...preferences, policy_version: 2,
      primary: { engine: "system", model_id: null, voice: null },
    };
    expect(buildCliCommand({ ...request, tts_preferences: captured }))
      .toContain(JSON.stringify(captured));
  });

  it.each([1, 3, 0, -1, 2.5, "2", null])("rejects unsupported policy version %j", policy_version => {
    const captured = Object.assign({}, preferences, { policy_version }) as unknown as TtsPreferences;
    expect(buildCliCommand({ ...request, tts_preferences: captured })).toBeUndefined();
  });

  it("rejects System model IDs, explicit voices and duplicate System selections", () => {
    const system = { engine: "system" as const, model_id: null, voice: null };
    for (const secondary of [
      { ...system, model_id: "pt_BR-faber-medium" },
      { ...system, voice: "Luciana" },
    ]) {
      expect(buildCliCommand({ ...request, tts_preferences: { ...preferences, secondary } })).toBeUndefined();
    }
    expect(buildCliCommand({ ...request, tts_preferences: {
      ...preferences, primary: system, secondary: system,
    } })).toBeUndefined();
  });

  it("shows the selected shell separately from the copyable command", () => {
    const recipe = buildCliReproduction({ ...request, localPath: "C:\\Books\\book.epub" });
    expect(recipe?.shell).toBe("PowerShell");
    const view = renderWithProviders(<StatusPanel entries={[]} phase="idle" showRawLog={false}
      onToggleRawLog={vi.fn()} cliCommand={recipe?.command} cliShell={recipe?.shell} />);
    expect(screen.getByText("PowerShell")).toBeVisible();
    const command = screen.getByTitle(recipe?.command ?? "");
    expect(command.textContent).toBe(recipe?.command);
    expect(command.textContent).toMatch(/^& converter-cli /);
    view.unmount();
    renderWithProviders(<DownloadsPanel downloads={[]} phase="success" onReset={vi.fn()}
      isBusy={false} log={[]} cliCommand={recipe?.command} cliShell={recipe?.shell} />, { locale: "en" });
    expect(screen.getByText("Reproduce with CLI")).toBeVisible();
    expect(screen.getByText("PowerShell")).toBeVisible();
    expect(screen.getByText(recipe?.command ?? "")).toBeVisible();
  });

  it("captures typed preferences instead of legacy form fields", () => {
    const command = buildCliCommand({
      ...request, engine: "edge", model: "obsolete-model", voice: "obsolete-voice",
    });
    expect(command).toContain("--tts-preferences-json '" + JSON.stringify(preferences) + "'");
    expect(command).not.toContain("obsolete");
    expect(command).not.toContain("preferences set");
    expect(command).toMatch(/^converter-cli convert /);
    expect(buildCliReproduction(request)?.shell).toBe("Bash/Zsh");
  });

  it("preserves a null Edge voice and revoked consent", () => {
    const captured: TtsPreferences = {
      primary: { engine: "edge", model_id: null, voice: null },
      secondary: null, allow_online_fallback: false,
    };
    expect(buildCliCommand({ ...request, tts_preferences: captured })).toContain(JSON.stringify(captured));
  });

  it("preserves an explicitly consented secondary", () => {
    const captured: TtsPreferences = {
      ...preferences,
      secondary: { engine: "edge", model_id: null, voice: "pt-BR-FranciscaNeural" },
      allow_online_fallback: true,
    };
    expect(buildCliCommand({ ...request, tts_preferences: captured })).toContain(JSON.stringify(captured));
  });

  it("maps the exact inclusive browser chapter range to explicit CLI positions", () => {
    const command = buildCliCommand({ ...request, chapters: "1-2", noParallel: true });
    expect(command).toContain("--chapter 'position:0' --chapter 'position:1' --no-parallel");
    expect(command).not.toContain("--chapter '1-2'");
    expect(buildCliCommand({ ...request, chapters: "3" })).toContain("--chapter 'position:2'");
  });

  it.each<Partial<ConversionFormValues>>([
    { localPath: undefined, fileName: "book.epub" },
    { localPath: "relative.epub" },
    { localPath: "--help.epub" },
    { localPath: "/books/book\n.epub" },
    { localPath: "/books/book\u0000.epub" },
    { tts_preferences: undefined },
    { footnoteMode: "skip" },
    { language: "pt-BR" },
    { priority: "1" },
    { formattingCues: false },
    { clearCache: true },
    { sections: "2" },
    { chapters: "0" },
    { chapters: "2-1" },
    { chapters: "1,2" },
    { chapters: "1-513" },
    { chapters: "9007199254740992" },
  ])("omits an unavailable or unrepresentable recipe (%j)", values => {
    expect(buildCliCommand({ ...request, ...values })).toBeUndefined();
  });

  it("rejects unconsented fallback, duplicate selections and unknown policy fields", () => {
    expect(buildCliCommand({ ...request, tts_preferences: {
      ...preferences, secondary: { engine: "edge", model_id: null, voice: null },
    } })).toBeUndefined();
    expect(buildCliCommand({ ...request, tts_preferences: {
      ...preferences, secondary: { ...preferences.primary },
    } })).toBeUndefined();
    expect(buildCliCommand({ ...request, tts_preferences:
      Object.assign({}, preferences, { unknown: true }),
    })).toBeUndefined();
  });
});
