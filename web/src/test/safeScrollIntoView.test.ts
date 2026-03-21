import { describe, expect, it, vi } from "vitest";
import {
  isRecoverableScrollError,
  safeScrollIntoView,
} from "../utils/safeScrollIntoView";

describe("safeScrollIntoView", () => {
  it("falls back silently when the browser throws the EmptyRanges quirk", () => {
    const target = document.createElement("div");
    const scrollIntoView = vi
      .fn()
      .mockImplementationOnce(() => {
        throw new ReferenceError("Can't find variable: EmptyRanges");
      })
      .mockImplementationOnce(() => undefined);
    target.scrollIntoView = scrollIntoView;

    expect(() =>
      safeScrollIntoView(target, { behavior: "smooth", block: "center" }),
    ).not.toThrow();
    expect(scrollIntoView).toHaveBeenCalledTimes(2);
  });

  it("keeps throwing unexpected scroll errors", () => {
    const target = document.createElement("div");
    target.scrollIntoView = vi.fn(() => {
      throw new Error("Other DOM error");
    });

    expect(() => safeScrollIntoView(target)).toThrow("Other DOM error");
    expect(isRecoverableScrollError(new Error("Other DOM error"))).toBe(false);
  });
});
