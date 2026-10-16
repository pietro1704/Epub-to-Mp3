import { act, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import App from "../App";
import { renderWithProviders } from "./testUtils";
import { HttpConversionClient, type ConversionClient } from "../services/ConversionService";
import type { JobSnapshot } from "../types/conversion";

function setTauriGlobal(value: unknown) {
  Object.defineProperty(window, "__TAURI__", {
    configurable: true,
    writable: true,
    value,
  });
}

afterEach(() => {
  setTauriGlobal(undefined);
});

describe("App integration", () => {
  it('opens embedded help without backend requests or restart controls', async () => {
    const user = userEvent.setup();
    const fetchMock = vi
      .spyOn(globalThis, 'fetch')
      .mockRejectedValue(new Error('No backend is available in the embedded browser runtime'));
    try {
      await act(async () => {
        renderWithProviders(<App />, { locale: 'en' });
      });
      await user.click(screen.getByRole('button', { name: 'Help & System' }));
      expect(screen.getByRole('button', { name: 'Help & System' })).toHaveAttribute(
        'aria-expanded',
        'true',
      );
      await act(async () => {
        await Promise.resolve();
      });

      expect(screen.getByRole('region', { name: 'Local conversion' })).toBeVisible();
      expect(screen.getByText('To prepare the offline voice, choose “Install Faber medium” in the form.')).toBeVisible();
      await user.click(within(screen.getByRole('complementary')).getByRole('button', { name: 'Close panel' }));
      expect(screen.queryByRole('region', { name: 'Local conversion' })).not.toBeInTheDocument();

      const backendRequests = fetchMock.mock.calls.filter(([input]) =>
        String(input).includes('/api/'),
      );
      expect(backendRequests).toEqual([]);
      expect(screen.queryByTestId('telemetry-panel')).not.toBeInTheDocument();
      expect(screen.queryByText('Restart Python backend')).not.toBeInTheDocument();
    } finally {
      fetchMock.mockRestore();
    }
  });

  it("loads explicit HTTP help diagnostics without duplicating the API prefix", async () => {
    const user = userEvent.setup();
    const diagnosticSignals: AbortSignal[] = [];
    const fetchMock = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input);
      if (/\/api\/(telemetry|system\/stats)/.test(url) && init?.signal) {
        diagnosticSignals.push(init.signal);
      }
      const data = url.endsWith("/summary")
        ? { engines: {}, ranked: [], totalSamples: 0 }
        : url.includes("/timeline") ? { points: [], count: 0 } : {};
      return new Response(JSON.stringify(data), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    });
    const client = new HttpConversionClient();
    try {
      await act(async () => {
        renderWithProviders(<App client={client} />, { locale: "en" });
      });
      expect(screen.queryByTestId("telemetry-panel")).not.toBeInTheDocument();
      await user.click(screen.getByRole("button", { name: "Help & System" }));
      expect(await screen.findByTestId("telemetry-panel")).toBeInTheDocument();
      expect(screen.getByText("Restart Python backend")).toBeInTheDocument();
      await waitFor(() => {
        const urls = fetchMock.mock.calls.map(([input]) => String(input));
        expect(urls).toContain("/api/telemetry/summary");
        expect(urls).toContain("/api/telemetry/timeline?limit=30");
        expect(urls).toContain("/api/system/stats");
        expect(urls.some((url) => url.includes("/api/api/"))).toBe(false);
      });
      expect(diagnosticSignals.length).toBeGreaterThanOrEqual(3);
      await user.click(within(screen.getByRole("complementary")).getByRole("button", { name: "Close panel" }));
      expect(screen.queryByTestId("telemetry-panel")).not.toBeInTheDocument();
      expect(diagnosticSignals.every((signal) => signal.aborted)).toBe(true);
      const closedSignals = [...diagnosticSignals];
      await user.click(screen.getByRole("button", { name: "Help & System" }));
      expect(await screen.findByTestId("telemetry-panel")).toBeInTheDocument();
      await waitFor(() => expect(diagnosticSignals.length).toBeGreaterThan(closedSignals.length));
      expect(closedSignals.every((signal) => signal.aborted)).toBe(true);
      expect(diagnosticSignals.slice(closedSignals.length).some((signal) => !signal.aborted)).toBe(true);
    } finally {
      fetchMock.mockRestore();
    }
  });


  it("shows the failed local job and its error without backend probes", async () => {
    const user = userEvent.setup();
    const failure = "Faber medium is not installed";
    const client: ConversionClient = {
      mode: "embedded",
      submit: vi.fn().mockResolvedValue({ jobId: "local-failed-job" }),
      fetch: vi.fn(),
      poll: vi.fn().mockResolvedValue({
        jobId: "local-failed-job",
        state: "failed",
        error: failure,
      } satisfies JobSnapshot),
    };
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockRejectedValue(new Error("The local client has no HTTP backend"));
    try {
      await act(async () => {
        renderWithProviders(<App client={client} />, { locale: "en" });
      });
      const input = await screen.findByLabelText(/book file/i);
      await user.upload(input, new File(["ebook"], "local-book.pdf", {
        type: "application/pdf",
      }));
      await user.click(screen.getByRole("button", { name: /convert now/i }));
      await waitFor(() => expect(client.poll).toHaveBeenCalledWith(
        "local-failed-job",
        expect.any(Object),
      ));
      await user.click(screen.getByRole("button", { name: "Help & System" }));
      const help = within(screen.getByRole("region", { name: "Local conversion" }));
      expect(await help.findByRole("alert")).toHaveTextContent(failure);
      expect(help.getByText("Request ID: local-failed-job")).toBeVisible();
      expect(help.getByText("Something went wrong")).toBeVisible();
      expect(fetchMock.mock.calls.filter(([input]) =>
        String(input).includes("/api/"),
      )).toEqual([]);
    } finally {
      fetchMock.mockRestore();
    }
  });

  it("runs full conversion flow with a custom client", async () => {
    const user = userEvent.setup();
    const submit = vi.fn().mockResolvedValue({ jobId: "job-777" });
    const poll = vi
      .fn()
      .mockImplementation(
        async (
          _jobId: string,
          options?: { onSnapshot?: (snapshot: JobSnapshot) => void },
        ) => {
          options?.onSnapshot?.({
            jobId: "job-777",
            state: "running",
            events: ["File loaded", "Synthesizing chapter 1"],
            detectedLanguage: "pt-BR",
            chaptersTotal: 2,
            chaptersCompleted: 1,
            currentChapter: "Chapter 1",
            progressPercent: 45,
          });
          return {
            jobId: "job-777",
            state: "finished",
            outputs: [
              {
                name: "Chapter 1.mp3",
                url: "https://cdn.example/audio-1.mp3",
              },
              {
                name: "Chapter 2.mp3",
                url: "https://cdn.example/audio-2.mp3",
              },
            ],
            detectedLanguage: "pt-BR",
            chaptersTotal: 2,
            chaptersCompleted: 2,
            currentChapter: "Chapter 2",
            progressPercent: 100,
          } satisfies JobSnapshot;
        },
      );

    const client: ConversionClient = {
      submit,
      fetch: vi.fn(),
      poll,
    };

    await act(async () => {
      renderWithProviders(<App client={client} />);
    });

    const file = new File(["ebook"], "historia.pdf", {
      type: "application/pdf",
    });
    const fileInput = await screen.findByLabelText(
      /arquivo do livro/i,
      {},
      { timeout: 5000 },
    );
    await user.upload(fileInput, file);

    await user.click(screen.getByRole("button", { name: /converter agora/i }));

    expect(submit).toHaveBeenCalledWith(
      expect.objectContaining({
        file,
        fileName: "historia.pdf",
      }),
    );
    await waitFor(() =>
      expect(poll).toHaveBeenCalledWith("job-777", expect.any(Object)),
    );
    await user.click(screen.getByRole("button", { name: "Ajuda & Sistema" }));
    const diagnostics = within(screen.getByRole("region", { name: "Conversão local" }));
    expect(await diagnostics.findByText("Código do pedido: job-777")).toBeVisible();
    expect(await diagnostics.findByText("Progresso geral: 100%")).toBeVisible();
  }, 10_000);

  it("reuses automatic upload and avoids resending the file", async () => {
    const user = userEvent.setup();
    const submit = vi.fn().mockResolvedValue({ jobId: "job-999" });
    const poll = vi.fn().mockResolvedValue({
      jobId: "job-999",
      state: "finished",
      outputs: [],
    } satisfies JobSnapshot);
    const upload = vi.fn().mockResolvedValue({
      uploadId: "upload-123",
      fileName: "historia.pdf",
      bookTitle: "Historia",
      bookAuthor: "Autor Teste",
      coverUrl: "/covers/historia.jpg",
    });

    const client: ConversionClient = {
      submit,
      fetch: vi.fn(),
      poll,
      upload,
    };

    await act(async () => {
      renderWithProviders(<App client={client} />);
    });

    const file = new File(["ebook"], "historia.pdf", {
      type: "application/pdf",
    });
    const fileInput = await screen.findByLabelText(
      /arquivo do livro/i,
      {},
      { timeout: 5000 },
    );
    await user.upload(fileInput, file);
    await waitFor(() => expect(upload).toHaveBeenCalledTimes(1));

    await waitFor(() =>
      expect(
        screen.getByRole("button", { name: /converter agora/i }),
      ).toBeEnabled(),
    );
    await user.click(screen.getByRole("button", { name: /converter agora/i }));

    await waitFor(() => {
      expect(submit).toHaveBeenCalledTimes(1);
      expect(submit).toHaveBeenCalledWith(
        expect.objectContaining({
          file: null,
          uploadId: "upload-123",
          fileName: "historia.pdf",
          bookTitle: "Historia",
          bookAuthor: "Autor Teste",
          coverUrl: "/covers/historia.jpg",
        }),
      );
    });
  });

  it("shows startup panel again when the Tauri sidecar restarts", async () => {
    const listeners = new Map<string, (payload: unknown) => void>();
    setTauriGlobal({
      core: {
        invoke: vi.fn().mockResolvedValue([]),
      },
      event: {
        listen: vi
          .fn()
          .mockImplementation(
            async (
              event: string,
              handler: (e: { payload: unknown }) => void,
            ) => {
              listeners.set(event, (payload: unknown) => handler({ payload }));
              return () => listeners.delete(event);
            },
          ),
      },
    });
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: false,
        json: vi.fn().mockResolvedValue({ status: "starting" }),
      }),
    );

    const client: ConversionClient = {
      submit: vi.fn(),
      fetch: vi.fn(),
      poll: vi.fn(),
    };

    await act(async () => {
      renderWithProviders(<App client={client} />, { locale: "en" });
    });

    expect(screen.getByText("Starting conversion engine…")).toBeInTheDocument();

    await act(async () => {
      listeners.get("tauri-startup-ready")?.(undefined);
    });

    await waitFor(() =>
      expect(
        screen.queryByText("Starting conversion engine…"),
      ).not.toBeInTheDocument(),
    );

    await act(async () => {
      listeners.get("tauri-server-restarting")?.(undefined);
      listeners.get("tauri-server-log")?.("Restarting sidecar");
    });

    expect(screen.getByText("Starting conversion engine…")).toBeInTheDocument();
    expect(screen.getByText("Restarting sidecar")).toBeInTheDocument();
  });

  it("renders a single desktop update banner when an update is available", async () => {
    const listeners = new Map<string, (payload: unknown) => void>();
    setTauriGlobal({
      core: {
        invoke: vi.fn().mockResolvedValue([]),
      },
      event: {
        listen: vi
          .fn()
          .mockImplementation(
            async (
              event: string,
              handler: (e: { payload: unknown }) => void,
            ) => {
              listeners.set(event, (payload: unknown) => handler({ payload }));
              return () => listeners.delete(event);
            },
          ),
      },
    });
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: vi.fn().mockResolvedValue({ status: "ok" }),
      }),
    );

    const client: ConversionClient = {
      submit: vi.fn(),
      fetch: vi.fn(),
      poll: vi.fn(),
    };

    await act(async () => {
      renderWithProviders(<App client={client} />, { locale: "en" });
    });

    await act(async () => {
      listeners.get("tauri-startup-ready")?.(undefined);
      listeners.get("tauri-update-available")?.({
        version: "2.0.1",
        body: "Bug fixes",
      });
    });

    await waitFor(() =>
      expect(screen.getByText("Update v2.0.1 available")).toBeInTheDocument(),
    );
    expect(
      screen.getAllByRole("button", { name: /install & restart/i }),
    ).toHaveLength(1);
  });

  it("shows an error when desktop update installation fails", async () => {
    const listeners = new Map<string, (payload: unknown) => void>();
    const downloadAndInstall = vi
      .fn()
      .mockRejectedValue(new Error("install failed"));
    setTauriGlobal({
      core: {
        invoke: vi.fn().mockResolvedValue([]),
      },
      event: {
        listen: vi
          .fn()
          .mockImplementation(
            async (
              event: string,
              handler: (e: { payload: unknown }) => void,
            ) => {
              listeners.set(event, (payload: unknown) => handler({ payload }));
              return () => listeners.delete(event);
            },
          ),
      },
      updater: {
        check: vi.fn().mockResolvedValue({
          available: true,
          version: "2.0.1",
          downloadAndInstall,
        }),
      },
    });
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: vi.fn().mockResolvedValue({ status: "ok" }),
      }),
    );

    const client: ConversionClient = {
      submit: vi.fn(),
      fetch: vi.fn(),
      poll: vi.fn(),
    };

    await act(async () => {
      renderWithProviders(<App client={client} />, { locale: "en" });
    });

    await act(async () => {
      listeners.get("tauri-startup-ready")?.(undefined);
      listeners.get("tauri-update-available")?.({
        version: "2.0.1",
        body: "Bug fixes",
      });
    });

    await userEvent
      .setup()
      .click(screen.getByRole("button", { name: /install & restart/i }));

    await waitFor(() =>
      expect(
        screen.getByText("Update installation failed. Please try again."),
      ).toBeInTheDocument(),
    );
    expect(downloadAndInstall).toHaveBeenCalledTimes(1);
  });
});
