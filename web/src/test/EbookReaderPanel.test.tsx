import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import EbookReaderPanel from "../components/EbookReaderPanel";
import { conversionClient } from "../services/ConversionService";
import { renderWithProviders } from "./testUtils";

describe("EbookReaderPanel", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    window.localStorage.clear();
  });

  it("loads full text and follows the active audio chapter", async () => {
    vi.spyOn(conversionClient, "getJobFullText").mockResolvedValue({
      jobId: "job-reader",
      bookTitle: "Livro Teste",
      bookAuthor: "Autora Teste",
      chapters: [
        {
          index: 0,
          name: "Prólogo",
          text: "Introdução curta.",
          html: "<p>Introdução curta.</p>",
          charCount: 17,
        },
        {
          index: 1,
          name: "Capítulo 1",
          text: "Primeiro trecho. Segundo trecho em destaque. Final.",
          html: "<p>Primeiro trecho. <strong>Segundo trecho em destaque.</strong> Final.</p>",
          charCount: 51,
        },
      ],
    });

    const { container } = renderWithProviders(
      <EbookReaderPanel
        jobId="job-reader"
        playback={{
          chapterIndex: 1,
          segmentIndex: 2,
          segmentText: "Segundo trecho em destaque.",
          isPlaying: true,
          started: true,
          waiting: false,
        }}
      />,
    );

    await waitFor(() =>
      expect(
        screen.getByRole("heading", { name: "Capítulo 1" }),
      ).toBeInTheDocument(),
    );
    await waitFor(() => {
      const shadowText =
        container.querySelector(".ebook-reader__content-host")?.shadowRoot
          ?.textContent ?? "";
      expect(shadowText).toContain("Segundo trecho em destaque.");
    });
    expect(screen.getByText(/Segmento 3/i)).toBeInTheDocument();
  });

  it("lets the user disable follow-audio and manually switch chapters", async () => {
    const user = userEvent.setup();
    vi.spyOn(conversionClient, "getJobFullText").mockResolvedValue({
      jobId: "job-reader",
      chapters: [
        {
          index: 0,
          name: "Chapter 0",
          text: "Alpha text.",
          html: "<p>Alpha text.</p>",
          charCount: 11,
        },
        {
          index: 1,
          name: "Chapter 1",
          text: "Beta text.",
          html: "<p>Beta text.</p>",
          charCount: 10,
        },
      ],
    });

    const { container } = renderWithProviders(
      <EbookReaderPanel
        jobId="job-reader"
        playback={{
          chapterIndex: 1,
          segmentIndex: 0,
          segmentText: "Beta text.",
          isPlaying: true,
          started: true,
          waiting: false,
        }}
      />,
      { locale: "en" },
    );

    await waitFor(() =>
      expect(
        screen.getByRole("heading", { name: "Chapter 1" }),
      ).toBeInTheDocument(),
    );

    await user.click(screen.getByRole("checkbox"));
    await user.click(screen.getByRole("button", { name: /Chapter 0/i }));

    expect(
      screen.getByRole("heading", { name: "Chapter 0" }),
    ).toBeInTheDocument();
    await waitFor(() => {
      const shadowText =
        container.querySelector(".ebook-reader__content-host")?.shadowRoot
          ?.textContent ?? "";
      expect(shadowText).toContain("Alpha text.");
    });
    expect(screen.getByText(/Manual reading/i)).toBeInTheDocument();
  });

  it("shows a single read-book CTA and calls the start handler", async () => {
    const user = userEvent.setup();
    const onRequestStart = vi.fn();
    vi.spyOn(conversionClient, "getJobFullText").mockResolvedValue({
      jobId: "job-reader",
      chapters: [
        {
          index: 1,
          name: "Capítulo 1",
          text: "Texto.",
          html: "<p>Texto.</p>",
          charCount: 6,
        },
      ],
    });

    renderWithProviders(
      <EbookReaderPanel jobId="job-reader" onRequestStart={onRequestStart} />,
    );

    const button = await screen.findByRole("button", { name: /Ler livro/i });
    await user.click(button);

    expect(onRequestStart).toHaveBeenCalledTimes(1);
  });

  it("renders the sequential player inside the reader", async () => {
    vi.spyOn(conversionClient, "getJobFullText").mockResolvedValue({
      jobId: "job-reader",
      chapters: [
        {
          index: 1,
          name: "Capítulo 1",
          text: "Texto.",
          html: "<p>Texto.</p>",
          charCount: 6,
        },
      ],
    });

    renderWithProviders(
      <EbookReaderPanel
        jobId="job-reader"
        chapterProgress={[
          {
            index: 1,
            name: "Capítulo 1",
            status: "processing",
            charCount: 6,
            completedSegments: 0,
            totalSegments: 1,
          },
        ]}
      />,
    );

    expect(await screen.findByText(/Leitura contínua/i)).toBeInTheDocument();
  });

  it("renders sanitized epub formatting in a minimal reading layout", async () => {
    vi.spyOn(conversionClient, "getJobFullText").mockResolvedValue({
      jobId: "job-reader",
      chapters: [
        {
          index: 1,
          name: "Capítulo 1",
          text: "Trecho em itálico e em negrito.",
          html: "<section><h2>Capítulo 1</h2><p><em>Trecho em itálico</em> e <strong>em negrito</strong>.</p><script>alert('x')</script></section>",
          charCount: 31,
        },
      ],
    });

    const { container } = renderWithProviders(
      <EbookReaderPanel jobId="job-reader" />,
    );

    await waitFor(() =>
      expect(
        screen.getByRole("heading", { name: "Capítulo 1" }),
      ).toBeInTheDocument(),
    );
    // Shadow DOM is populated in a separate useEffect; wait for it explicitly
    // so the test doesn't race in slower CI environments.
    await waitFor(() => {
      const shadowRoot = container.querySelector(
        ".ebook-reader__content-host",
      )?.shadowRoot;
      expect(shadowRoot?.querySelector("em")?.textContent).toBe(
        "Trecho em itálico",
      );
      expect(shadowRoot?.querySelector("strong")?.textContent).toBe(
        "em negrito",
      );
      expect(shadowRoot?.textContent || "").toContain(
        "Trecho em itálico e em negrito.",
      );
      expect(shadowRoot?.textContent || "").not.toContain("alert('x')");
    });
  });

  it("splits long chapters into pages and lets the user flip them", async () => {
    const user = userEvent.setup();
    const longParagraph = "Texto longo ".repeat(260);
    vi.spyOn(conversionClient, "getJobFullText").mockResolvedValue({
      jobId: "job-reader",
      chapters: [
        {
          index: 1,
          name: "Capítulo 1",
          text: `${longParagraph}\n\n${longParagraph}`,
          html: `<p>${longParagraph}</p><p>${longParagraph}</p>`,
          css: "",
          charCount: longParagraph.length * 2,
        },
      ],
    });

    renderWithProviders(<EbookReaderPanel jobId="job-reader" />);

    await waitFor(() =>
      expect(screen.getAllByText(/Página 1 de/i).length).toBeGreaterThan(0),
    );
    const nextPage = screen.getByRole("button", { name: /Próxima página/i });
    expect(nextPage).toBeEnabled();
    await user.click(nextPage);
    expect(screen.getAllByText(/Página 2 de/i).length).toBeGreaterThan(0);
  });
});
