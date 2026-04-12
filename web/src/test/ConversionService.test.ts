import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import {
  HttpConversionClient,
  normalizeAssetUrl,
} from "../services/ConversionService";

class MockEventSource {
  static instances: MockEventSource[] = [];

  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: (() => void) | null = null;
  closed = false;

  constructor(
    public readonly url: string,
    public readonly _options?: { withCredentials?: boolean },
  ) {
    MockEventSource.instances.push(this);
  }

  addEventListener(_event: string, _handler: (event: MessageEvent) => void) {}

  close() {
    this.closed = true;
  }
}

beforeEach(() => {
  MockEventSource.instances = [];
});

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

  test("falls back to HTTP polling after SSE retries are exhausted", async () => {
    vi.useFakeTimers();
    vi.stubGlobal("EventSource", MockEventSource);

    const fetchMock = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          jobId: "job-sse",
          state: "finished",
          outputs: [],
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" },
        },
      ),
    );

    const client = new HttpConversionClient("");
    const resultPromise = client.poll("job-sse");

    expect(MockEventSource.instances).toHaveLength(1);

    MockEventSource.instances[0].onerror?.();
    await vi.advanceTimersByTimeAsync(2000);
    expect(MockEventSource.instances).toHaveLength(2);

    MockEventSource.instances[1].onerror?.();
    await vi.advanceTimersByTimeAsync(4000);
    expect(MockEventSource.instances).toHaveLength(3);

    MockEventSource.instances[2].onerror?.();
    await vi.advanceTimersByTimeAsync(8000);
    expect(MockEventSource.instances).toHaveLength(4);

    MockEventSource.instances[3].onerror?.();

    const result = await resultPromise;

    expect(fetchMock).toHaveBeenCalledWith(
      `${window.location.origin}/api/jobs/job-sse`,
      {
        method: "GET",
        signal: undefined,
      },
    );
    expect(result.state).toBe("finished");
    vi.useRealTimers();
  });
});
