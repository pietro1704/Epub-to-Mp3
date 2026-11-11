import { describe, it, expect } from "vitest";
import { translations } from "../i18n/translations";

const NEW_STATUS_KEYS = [
  "ttsEngineLabel",
  "speedLabel",
  "terminalLogLabel",
  "coverPhaseSubmitting",
  "coverPhasePolling",
  "coverPhaseSuccess",
  "coverPhaseError",
  "coverPhaseDefault",
] as const;

describe("i18n coverage for new status keys", () => {
  for (const locale of ["pt", "en"] as const) {
    describe(`locale: ${locale}`, () => {
      for (const key of NEW_STATUS_KEYS) {
        it(`status.${key} exists`, () => {
          const value = (
            translations[locale].status as Record<string, unknown>
          )[key];
          expect(value).toBeDefined();
          if (typeof value === "string") {
            expect(value.length).toBeGreaterThan(0);
          } else {
            expect(typeof value).toBe("function");
          }
        });
      }
    });
  }
});
