import { act, renderHook } from "@testing-library/react";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { useConversionFlow } from "../hooks/useConversionFlow";
import type { ConversionClient } from "../services/ConversionService";
import type { ConversionFormValues, JobSnapshot } from "../types/conversion";
import { createProvidersWrapper } from "./testUtils";
import { conversionCache } from "../services/ConversionCache";

describe("useConversionFlow", () => {
  beforeEach(() => {
    // Isolate localStorage from real data
    localStorage.clear();
  });

  const file = new File(["data"], "book.epub", {
    type: "application/epub+zip",
  });
  const request: ConversionFormValues = {
    file,
    engine: "edge",
    footnoteMode: "inline",
  };

  it("completes conversion successfully and records events", async () => {
    const submit = vi.fn().mockResolvedValue({ jobId: "123" });
    const poll = vi
      .fn()
      .mockImplementation(
        async (
          _jobId: string,
          options?: { onSnapshot?: (snapshot: JobSnapshot) => void },
        ) => {
          options?.onSnapshot?.({
            jobId: "123",
            state: "running",
            events: ["Extracting chapters", "Generating audio"],
          });
          return {
            jobId: "123",
            state: "finished",
            outputs: [{ name: "capitulo-1.mp3", url: "/audio/1.mp3" }],
          } satisfies JobSnapshot;
        },
      );

    const client: ConversionClient = {
      submit,
      fetch: vi.fn(),
      poll,
    };

    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper("pt"),
    });

    await act(async () => {
      await result.current.submit(request);
    });

    expect(submit).toHaveBeenCalledWith(request);
    expect(poll).toHaveBeenCalledWith("123", expect.any(Object));
    expect(result.current.state.phase).toBe("success");
    expect(result.current.state.downloads).toHaveLength(1);
    expect(result.current.state.etaSeconds).toBe(0);
    expect(result.current.state.summary?.progressPercent).toBe(100);
    const messages = result.current.state.log.map((entry) => entry.message);
    expect(messages).toEqual([
      expect.stringMatching(/Enviando arquivo/i),
      expect.stringContaining("Pedido 123"),
      "Extracting chapters",
      "Generating audio",
      expect.stringContaining("Conversão finalizada"),
    ]);
  });

  it("propagates error when conversion fails", async () => {
    const submit = vi.fn().mockResolvedValue({ jobId: "321" });
    const poll = vi.fn().mockResolvedValue({
      jobId: "321",
      state: "failed",
      error: "Falha na síntese",
    } satisfies JobSnapshot);

    const client: ConversionClient = {
      submit,
      fetch: vi.fn(),
      poll,
    };

    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper("pt"),
    });

    await act(async () => {
      await result.current.submit(request);
    });

    expect(result.current.state.phase).toBe("error");
    expect(result.current.state.error).toBe("Falha na síntese");
    expect(result.current.state.etaSeconds).toBe(0);
    const lastMessage = result.current.state.log.at(-1)?.message ?? "";
    expect(lastMessage).toContain("Falha");
  });

  it("removes file from payload when a prior upload already exists", async () => {
    const submit = vi.fn().mockResolvedValue({ jobId: "555" });
    const poll = vi.fn().mockResolvedValue({
      jobId: "555",
      state: "finished",
      outputs: [],
    } satisfies JobSnapshot);

    const client: ConversionClient = {
      submit,
      fetch: vi.fn(),
      poll,
    };

    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper("pt"),
    });

    const file = new File(["data"], "book.epub", {
      type: "application/epub+zip",
    });
    await act(async () => {
      await result.current.submit({
        file,
        fileName: "book.epub",
        uploadId: "upload-xyz",
        engine: "edge",
        footnoteMode: "inline",
      });
    });

    expect(submit).toHaveBeenCalledWith(
      expect.objectContaining({
        file: null,
        uploadId: "upload-xyz",
        fileName: "book.epub",
      }),
    );

    const firstMessage = result.current.state.log[0]?.message ?? "";
    expect(firstMessage).toContain("arquivo já enviado");
  });

  it("keeps queued upload metadata visible while the next job starts", async () => {
    const submit = vi
      .fn()
      .mockResolvedValueOnce({ jobId: "job-1" })
      .mockResolvedValueOnce({ jobId: "job-2" });
    const poll = vi
      .fn()
      .mockResolvedValueOnce({
        jobId: "job-1",
        state: "finished",
        outputs: [],
      } satisfies JobSnapshot)
      .mockImplementationOnce(
        async (
          _jobId: string,
          options?: { onSnapshot?: (snapshot: JobSnapshot) => void },
        ) => {
          options?.onSnapshot?.({
            jobId: "job-2",
            state: "running",
            events: ["Starting queued upload"],
            progressPercent: 10,
          });
          return {
            jobId: "job-2",
            state: "finished",
            outputs: [],
            progressPercent: 100,
          } satisfies JobSnapshot;
        },
      );

    const client: ConversionClient = {
      submit,
      fetch: vi.fn(),
      poll,
    };

    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper("en"),
    });

    await act(async () => {
      await result.current.submit(request, {
        batchQueue: [
          {
            file: null,
            fileName: "queued.epub",
            uploadId: "upload-queued",
            bookTitle: "Queued Book",
            bookAuthor: "Queued Author",
            coverUrl: "/covers/queued.jpg",
            engine: "edge",
            footnoteMode: "inline",
          },
        ],
      });
    });

    expect(submit).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({
        file: null,
        uploadId: "upload-queued",
        bookTitle: "Queued Book",
        bookAuthor: "Queued Author",
        coverUrl: "/covers/queued.jpg",
      }),
    );
    expect(result.current.state.phase).toBe("success");
    expect(result.current.state.bookTitle).toBe("Queued Book");
    expect(result.current.state.bookAuthor).toBe("Queued Author");
    expect(result.current.state.coverUrl).toBe("/covers/queued.jpg");
  });

  it("reset() returns state to idle and clears log", async () => {
    const submit = vi.fn().mockResolvedValue({ jobId: "777" });
    const poll = vi.fn().mockResolvedValue({
      jobId: "777",
      state: "finished",
      outputs: [],
    } satisfies JobSnapshot);

    const client: ConversionClient = { submit, fetch: vi.fn(), poll };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper("pt"),
    });

    await act(async () => {
      await result.current.submit(request);
    });

    expect(result.current.state.phase).toBe("success");
    expect(result.current.state.log.length).toBeGreaterThan(0);

    act(() => {
      result.current.reset();
    });

    expect(result.current.state.phase).toBe("idle");
    expect(result.current.state.log).toHaveLength(0);
    expect(result.current.state.error).toBeUndefined();
  });

  it("records chapter progress updates from snapshot", async () => {
    const submit = vi.fn().mockResolvedValue({ jobId: "999" });
    const poll = vi
      .fn()
      .mockImplementation(
        async (
          _jobId: string,
          options?: { onSnapshot?: (snapshot: JobSnapshot) => void },
        ) => {
          options?.onSnapshot?.({
            jobId: "999",
            state: "running",
            events: [],
            chapterProgress: [
              { index: 1, name: "Ch 1", status: "completed", engine: "edge" },
              { index: 2, name: "Ch 2", status: "processing", engine: "edge" },
            ],
          });
          return {
            jobId: "999",
            state: "finished",
            outputs: [],
            chapterProgress: [
              { index: 1, name: "Ch 1", status: "completed", engine: "edge" },
              { index: 2, name: "Ch 2", status: "completed", engine: "edge" },
            ],
          } satisfies JobSnapshot;
        },
      );

    const client: ConversionClient = { submit, fetch: vi.fn(), poll };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper("en"),
    });

    await act(async () => {
      await result.current.submit(request);
    });

    expect(result.current.state.phase).toBe("success");
    const progress = result.current.state.summary?.chapterProgress;
    expect(progress).toBeDefined();
    expect(progress?.length).toBe(2);
    expect(progress?.[0].status).toBe("completed");
  });

  it("surfaces multiple download assets from finished snapshot", async () => {
    const submit = vi.fn().mockResolvedValue({ jobId: "multi" });
    const poll = vi.fn().mockResolvedValue({
      jobId: "multi",
      state: "finished",
      outputs: [
        { name: "ch-1.mp3", url: "/audio/ch-1.mp3" },
        { name: "ch-2.mp3", url: "/audio/ch-2.mp3" },
        { name: "book.zip", url: "/audio/book.zip" },
      ],
    } satisfies JobSnapshot);

    const client: ConversionClient = { submit, fetch: vi.fn(), poll };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper("en"),
    });

    await act(async () => {
      await result.current.submit(request);
    });

    expect(result.current.state.phase).toBe("success");
    expect(result.current.state.downloads).toHaveLength(3);
    const names = result.current.state.downloads.map((d) => d.name);
    expect(names).toContain("ch-1.mp3");
    expect(names).toContain("book.zip");
  });

  it("saves pending batch to localStorage during drainQueue and clears on completion", async () => {
    const saveSpy = vi.spyOn(conversionCache, "savePendingBatch");
    const clearSpy = vi.spyOn(conversionCache, "clearPendingBatch");

    const submit = vi.fn().mockResolvedValue({ jobId: "persist" });
    const poll = vi.fn().mockResolvedValue({
      jobId: "persist",
      state: "finished",
      outputs: [],
    } satisfies JobSnapshot);

    const client: ConversionClient = { submit, fetch: vi.fn(), poll };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper("en"),
    });

    await act(async () => {
      await result.current.submit(request);
    });

    // savePendingBatch called at least once (on submit + before each job)
    expect(saveSpy).toHaveBeenCalled();
    // clearPendingBatch called after queue drains
    expect(clearSpy).toHaveBeenCalled();
  });

  it("dismissSavedBatch clears state and localStorage", () => {
    conversionCache.savePendingBatch([
      { file: null, uploadId: "u1", engine: "edge", footnoteMode: "inline" },
    ]);

    const client: ConversionClient = {
      submit: vi.fn(),
      fetch: vi.fn(),
      poll: vi.fn(),
    };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper("en"),
    });

    // savedBatch should be populated from localStorage
    expect(result.current.savedBatch).not.toBeNull();

    act(() => {
      result.current.dismissSavedBatch();
    });

    expect(result.current.savedBatch).toBeNull();
    expect(conversionCache.loadPendingBatch()).toBeNull();
  });

  it("resumeBatch skips items with no file and no uploadId", async () => {
    const submitMock = vi.fn().mockResolvedValue({ jobId: "resume1" });
    const poll = vi.fn().mockResolvedValue({
      jobId: "resume1",
      state: "finished",
      outputs: [],
    } satisfies JobSnapshot);

    const client: ConversionClient = {
      submit: submitMock,
      fetch: vi.fn(),
      poll,
    };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper("en"),
    });

    const lostItem: ConversionFormValues = {
      file: null, // file lost during serialisation
      engine: "edge",
      footnoteMode: "inline",
    };
    const validItem: ConversionFormValues = {
      file: null,
      uploadId: "existing-upload",
      fileName: "book2.epub",
      engine: "edge",
      footnoteMode: "inline",
    };

    await act(async () => {
      await result.current.resumeBatch([lostItem, validItem]);
    });

    // lostItem is skipped; submitMock should be called with validItem
    expect(submitMock).toHaveBeenCalledWith(
      expect.objectContaining({ uploadId: "existing-upload" }),
    );
    expect(result.current.savedBatch).toBeNull();
  });

  it("resumeBatch does nothing when all items have no file and no uploadId", async () => {
    const submitMock = vi.fn();
    const client: ConversionClient = {
      submit: submitMock,
      fetch: vi.fn(),
      poll: vi.fn(),
    };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper("en"),
    });

    const lostItem: ConversionFormValues = {
      file: null,
      engine: "edge",
      footnoteMode: "inline",
    };

    await act(async () => {
      await result.current.resumeBatch([lostItem]);
    });

    expect(submitMock).not.toHaveBeenCalled();
    expect(result.current.savedBatch).toBeNull();
  });
});
