import { act, renderHook } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { useConversionFlow } from "../hooks/useConversionFlow";
import type { ConversionClient } from "../services/ConversionService";
import type { ConversionFormValues, JobSnapshot } from "../types/conversion";
import { createProvidersWrapper } from "./testUtils";

describe("useConversionFlow", () => {
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
});
