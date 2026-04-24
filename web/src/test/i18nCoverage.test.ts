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
  "cachedJobsTitle",
  "cachedJobsClose",
  "cachedJobsSingular",
  "cachedJobsPlural",
  "cachedJobsResume",
  "cachedJobsRemove",
  "cachedJobsJustNow",
  "cachedJobsDaysAgo",
  "cachedJobsHoursAgo",
  "cachedJobsMinutesAgo",
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

      it("cachedJobsPlural returns count in string", () => {
        const fn = translations[locale].status.cachedJobsPlural;
        const result = fn(3);
        expect(result).toContain("3");
      });

      it("cachedJobsDaysAgo returns count in string", () => {
        const fn = translations[locale].status.cachedJobsDaysAgo;
        expect(fn(2)).toContain("2");
      });

      it("cachedJobsHoursAgo returns count in string", () => {
        const fn = translations[locale].status.cachedJobsHoursAgo;
        expect(fn(5)).toContain("5");
      });

      it("cachedJobsMinutesAgo returns count in string", () => {
        const fn = translations[locale].status.cachedJobsMinutesAgo;
        expect(fn(10)).toContain("10");
      });

      it("cachedJobsRemove includes file name", () => {
        const fn = translations[locale].status.cachedJobsRemove;
        expect(fn("book.epub")).toContain("book.epub");
      });
    });
  }
});
