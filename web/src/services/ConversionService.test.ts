import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  HttpConversionClient,
  normalizeErrorMessage,
} from "./ConversionService";

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

/**
 * SSE idle watchdog: Tauri WKWebView keeps the TCP socket alive during long
 * backend silences (Edge slow mode), but `onmessage`/`onerror` never fire —
 * UI freezes. The client must auto-reconnect after a bounded idle window.
 */
describe("HttpConversionClient SSE idle watchdog", () => {
  class FakeEventSource {
    static instances: FakeEventSource[] = [];
    public onmessage: ((ev: MessageEvent) => void) | null = null;
    public onerror: (() => void) | null = null;
    public closed = false;
    public listeners: Record<string, Array<(ev: MessageEvent) => void>> = {};
    constructor(public url: string) {
      FakeEventSource.instances.push(this);
    }
    addEventListener(name: string, fn: (ev: MessageEvent) => void) {
      (this.listeners[name] = this.listeners[name] ?? []).push(fn);
    }
    close() {
      this.closed = true;
    }
  }

  let originalEventSource: unknown;

  beforeEach(() => {
    vi.useFakeTimers();
    FakeEventSource.instances = [];
    originalEventSource = (globalThis as Record<string, unknown>).EventSource;
    (globalThis as Record<string, unknown>).EventSource =
      FakeEventSource as unknown as typeof EventSource;
  });

  afterEach(() => {
    (globalThis as Record<string, unknown>).EventSource = originalEventSource;
    vi.useRealTimers();
  });

  it("reconnects after 25s of silence", async () => {
    const client = new HttpConversionClient("http://localhost:8000");
    // Fire and forget — we only care about the EventSource lifecycle.
    void client.poll("job-idle", { signal: new AbortController().signal });

    await vi.advanceTimersByTimeAsync(0);
    expect(FakeEventSource.instances.length).toBe(1);
    const first = FakeEventSource.instances[0];
    expect(first.closed).toBe(false);

    // Idle window elapses without any onmessage. The watchdog must tear down
    // the first EventSource and schedule a reconnect (waits 2s retry delay).
    await vi.advanceTimersByTimeAsync(25_000);
    expect(first.closed).toBe(true);

    await vi.advanceTimersByTimeAsync(2_000);
    expect(FakeEventSource.instances.length).toBe(2);
    const second = FakeEventSource.instances[1];
    expect(second.closed).toBe(false);
  });

  it("does not reconnect while messages keep arriving", async () => {
    const client = new HttpConversionClient("http://localhost:8000");
    void client.poll("job-live", { signal: new AbortController().signal });

    await vi.advanceTimersByTimeAsync(0);
    expect(FakeEventSource.instances.length).toBe(1);
    const source = FakeEventSource.instances[0];

    // Simulate a message every 10s — well inside the 25s watchdog.
    for (let i = 0; i < 4; i += 1) {
      await vi.advanceTimersByTimeAsync(10_000);
      source.onmessage?.(
        new MessageEvent("message", {
          data: JSON.stringify({ jobId: "job-live", state: "running" }),
        }),
      );
    }

    expect(source.closed).toBe(false);
    expect(FakeEventSource.instances.length).toBe(1);
  });
});
