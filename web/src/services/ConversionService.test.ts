import { describe, expect, it } from "vitest";
import { normalizeErrorMessage } from "./ConversionService";

describe("normalizeErrorMessage", () => {
  it("uses JSON message when available", () => {
    const message = normalizeErrorMessage(
      400,
      "Bad Request",
      JSON.stringify({ detail: "Invalid file" }),
    );
    expect(message).toBe("Invalid file");
  });

  it("ignores HTML and shows friendly fallback", () => {
    const message = normalizeErrorMessage(
      500,
      "Internal Server Error",
      "<!DOCTYPE html><html><body>500</body></html>",
    );
    expect(message).toContain("internal error");
  });

  it("returns friendly guidance for rate limiting", () => {
    const message = normalizeErrorMessage(
      429,
      "Too Many Requests",
      "Rate limit exceeded",
    );
    expect(message).toContain("rate-limiting requests");
  });
});
