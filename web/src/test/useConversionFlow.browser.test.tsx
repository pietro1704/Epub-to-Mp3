import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../wasm/converter_wasm", () => ({
  default: vi.fn(),
  ConversionSession: vi.fn(),
  inspect_epub: vi.fn(),
}));

import { useConversionFlow } from "../hooks/useConversionFlow";
import {
  BrowserConversionClient,
  type BrowserRuntime,
} from "../services/BrowserConversionClient";
import { MemoryBrowserJobStore } from "../services/BrowserJobStore";
import { faber } from "../services/TtsPreferences";
import type { ConversionFormValues } from "../types/conversion";
import { createProvidersWrapper } from "./testUtils";

function browserFixture() {
  let release!: () => void;
  const pending = new Promise<void>((resolve) => { release = resolve; });
  let accepted = false;
  const session = {
    next_segment: () => accepted ? "null" : JSON.stringify({
      chapter: 0, index: 0, total: 1, text: "Fixture", selection: faber,
      fallback_used: false,
    }),
    provider_failed: vi.fn(),
    accept_audio: () => { accepted = true; return true; },
    chapter_audio: () => new Uint8Array([1, 2, 3]),
    cancel: vi.fn(),
    free: vi.fn(),
  };
  const cancelSynthesis = vi.fn(() => release());
  const runtime: BrowserRuntime = {
    inspect: async () => ({
      bookTitle: "Fixture",
      chapters: [{ index: 0, name: "Chapter", text: "Fixture", charCount: 7 }],
    }),
    create: async () => session,
    synthesize: vi.fn(async () => {
      await pending;
      return new Uint8Array([1, 2, 3]);
    }),
    cancelSynthesis,
  };
  const store = new MemoryBrowserJobStore();
  return { client: new BrowserConversionClient(runtime, store), store, runtime,
    session, cancelSynthesis, release };
}

const request = (): ConversionFormValues => ({
  file: new File(["fixture"], "fixture.epub"),
  engine: "piper",
  footnoteMode: "inline",
  tts_preferences: {
    primary: { ...faber }, secondary: null, allow_online_fallback: false,
  },
});

describe("useConversionFlow with browser job ownership", () => {
  beforeEach(() => {
    localStorage.clear();
    vi.stubGlobal("fetch", vi.fn(() => { throw new Error("Unexpected network request"); }));
    vi.stubGlobal("URL", class extends URL {
      static createObjectURL = vi.fn(() => "blob:fixture");
      static revokeObjectURL = vi.fn();
    });
  });

  afterEach(() => { vi.unstubAllGlobals(); });

  it("cancels and removes its browser job without cancelling another client's job", async () => {
    const first = browserFixture();
    const second = browserFixture();
    const other = await second.client.submit(request());
    const { result, unmount } = renderHook(() => useConversionFlow(first.client), {
      wrapper: createProvidersWrapper("en"),
    });
    let submitting: Promise<void> = Promise.resolve();
    try {
      act(() => { submitting = result.current.submit(request()); });
      await waitFor(() => {
        expect(result.current.state.phase).toBe("polling");
        expect(first.runtime.synthesize).toHaveBeenCalledOnce();
        expect(second.runtime.synthesize).toHaveBeenCalledOnce();
      });
      const target = result.current.state.jobId;
      expect(target).toBeTruthy();
      expect(target).not.toBe(other.jobId);

      await act(async () => { expect(await result.current.cancel()).toBe(true); });
      await waitFor(() => expect(first.cancelSynthesis).toHaveBeenCalledOnce());
      await waitFor(async () => expect(await first.store.list()).toEqual([]));
      expect(first.session.cancel).toHaveBeenCalledOnce();
      expect(second.cancelSynthesis).not.toHaveBeenCalled();
      expect(second.session.cancel).not.toHaveBeenCalled();
      expect((await second.client.fetch(other.jobId)).state).toBe("running");
      expect((await second.store.list()).map((job) => job.jobId)).toEqual([other.jobId]);

      second.release();
      const finished = await second.client.poll(other.jobId, { intervalMs: 1 });
      expect(finished.state).toBe("finished");
      expect(finished.outputs).toHaveLength(1);
    } finally {
      unmount();
      first.release();
      second.release();
      await submitting;
      await second.client.poll(other.jobId, { intervalMs: 1 });
    }
  });
});
