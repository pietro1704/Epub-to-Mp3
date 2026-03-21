import { afterEach, describe, expect, test, vi } from "vitest";
import {
  HttpConversionClient,
  normalizeAssetUrl,
} from "../services/ConversionService";

afterEach(() => {
  vi.restoreAllMocks();
});

describe("normalizeAssetUrl", () => {
  test("returns absolute URLs unchanged", () => {
    const url = "https://cdn.example.com/audio/chapter.mp3";
    expect(normalizeAssetUrl("https://api.example.com", url)).toBe(url);
  });

  test("combines absolute base with relative asset", () => {
    const result = normalizeAssetUrl(
      "https://api.example.com",
      "/api/outputs/job/file.mp3",
    );
    expect(result).toBe("https://api.example.com/api/outputs/job/file.mp3");
  });

  test("uses window origin when base is relative", () => {
    const result = normalizeAssetUrl("/api", "/api/outputs/job/file.mp3");
    expect(result).toBe(`${window.location.origin}/api/outputs/job/file.mp3`);
  });

  test("falls back to origin when base is empty", () => {
    const result = normalizeAssetUrl("", "outputs/job/file.mp3");
    expect(result).toBe(`${window.location.origin}/outputs/job/file.mp3`);
  });

  test("normalizes the full text payload", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          jobId: "job-42",
          chapters: [
            {
              name: "Intro",
              text: "Hello world",
            },
          ],
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" },
        },
      ),
    );
    const client = new HttpConversionClient("https://api.example.com");

    const payload = await client.getJobFullText("job-42");

    expect(fetchMock).toHaveBeenCalledWith(
      "https://api.example.com/api/jobs/job-42/fulltext",
      { method: "GET" },
    );
    expect(payload).toEqual({
      jobId: "job-42",
      chapters: [
        {
          index: 0,
          name: "Intro",
          text: "Hello world",
          charCount: 11,
        },
      ],
    });
  });
});
