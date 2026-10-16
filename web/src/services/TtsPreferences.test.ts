import { beforeEach, describe, expect, it } from "vitest";
import { edge, effectiveTtsPreferences, faber, loadTtsPreferences, saveTtsPreferences } from "./TtsPreferences";
beforeEach(() => localStorage.clear());
describe("TTS preferences", () => {
  it("removes an identical manual secondary but preserves distinct voices", () => {
    const saved = { primary: faber, secondary: edge, allow_online_fallback: true };
    expect(effectiveTtsPreferences(saved, { engine: "edge" }, true)).toEqual({
      primary: { engine: "edge" }, secondary: null, allow_online_fallback: false,
    });
    expect(effectiveTtsPreferences(saved, { ...edge, voice: "pt-BR-AntonioNeural" }, true).secondary).toEqual(edge);
    expect(saved.secondary).toEqual(edge);
    expect(effectiveTtsPreferences({ ...saved, primary: edge, secondary: faber }, faber, true).secondary).toBeNull();
  });
  it("defaults offline and preserves explicit old choices", () => {
    expect(loadTtsPreferences()).toEqual({ primary: faber, secondary: null, allow_online_fallback: false });
    saveTtsPreferences({ primary: edge, secondary: faber, allow_online_fallback: false });
    expect(loadTtsPreferences().primary).toEqual(edge);
  });
  it("makes overrides strict unless secondary is explicitly requested", () => {
    const saved = { primary: faber, secondary: edge, allow_online_fallback: true };
    expect(effectiveTtsPreferences(saved, faber)).toEqual({ primary: faber, secondary: null, allow_online_fallback: false });
    const inherited = effectiveTtsPreferences(saved, null);
    inherited.primary.engine = "edge";
    expect(saved.primary.engine).toBe("piper");
    expect(effectiveTtsPreferences(saved, faber, true).secondary).toEqual(edge);
  });
});
