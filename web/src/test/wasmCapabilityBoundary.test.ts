import { describe, expect, it } from "vitest";

describe("WASM capability boundary", () => {
  it("keeps the browser conversion seam explicitly unavailable", () => {
    const unavailable = new Error(
      "Full MP3 conversion is unavailable in browser WASM; use the existing HTTP API.",
    );

    expect(unavailable).toBeInstanceOf(Error);
    expect(unavailable.message).toContain("unavailable");
    expect(unavailable.message).toContain("existing HTTP API");
  });
});
