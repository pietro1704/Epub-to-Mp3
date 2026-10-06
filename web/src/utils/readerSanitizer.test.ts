import { describe, expect, it } from "vitest";
import { sanitizeReaderCss, sanitizeReaderHtml } from "./readerSanitizer";

describe("reader content sanitizer", () => {
  it("removes active HTML while preserving safe EPUB content", () => {
    const sanitized = sanitizeReaderHtml(
      '<p class="lead" onclick="alert(1)">Safe <strong>text</strong>.</p>' +
        "<script>alert(2)</script>" +
        '<a href="javascript:alert(3)">unsafe</a>' +
        '<a href="#chapter">safe link</a>',
    );

    expect(sanitized).not.toContain("script");
    expect(sanitized).not.toContain("onclick");
    expect(sanitized).not.toContain("javascript:");
    expect(sanitized).toContain('<p class="lead">');
    expect(sanitized).toContain("<strong>text</strong>");
    expect(sanitized).toContain('href="#chapter"');
  });

  it("removes unsafe CSS constructs before the style element is built", () => {
    const sanitized = sanitizeReaderCss(
      ".lead { color: #123456; display: block; background: url(javascript:alert(1)); }" +
        "@import url(https://evil.example/style.css);" +
        ".x { width: expression(alert(1)); behavior: url(evil.htc); }",
    );

    expect(sanitized.toLowerCase()).not.toContain("javascript:");
    expect(sanitized.toLowerCase()).not.toContain("@import");
    expect(sanitized.toLowerCase()).not.toContain("expression");
    expect(sanitized.toLowerCase()).not.toContain("behavior");
    expect(sanitized).toContain("color: #123456");
    expect(sanitized).toContain("display: block");
  });
});
