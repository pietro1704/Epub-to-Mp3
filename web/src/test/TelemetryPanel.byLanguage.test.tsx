import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor, cleanup } from "@testing-library/react";
import TelemetryPanel from "../components/TelemetryPanel";

const SUMMARY_WITH_LANGS = {
  engines: {
    edge: {
      samples: 2,
      avg_chars_per_second: 125,
      max_chars_per_second: 200,
      min_chars_per_second: 50,
    },
  },
  ranked: ["edge"],
  totalSamples: 2,
  byLanguage: {
    edge: {
      pt: {
        samples: 1,
        avg_chars_per_second: 50,
        max_chars_per_second: 50,
        min_chars_per_second: 50,
      },
      en: {
        samples: 1,
        avg_chars_per_second: 200,
        max_chars_per_second: 200,
        min_chars_per_second: 200,
      },
    },
  },
};

const TIMELINE_EMPTY = { points: [], count: 0 };

describe("TelemetryPanel byLanguage breakdown", () => {
  beforeEach(() => {
    vi.spyOn(global, "fetch").mockImplementation((async (url: string) => {
      const body = url.includes("/summary")
        ? SUMMARY_WITH_LANGS
        : TIMELINE_EMPTY;
      return new Response(JSON.stringify(body), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as unknown as typeof fetch);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    cleanup();
  });

  it("renders one row per (engine, language) tuple", async () => {
    render(<TelemetryPanel />);
    await waitFor(() => {
      expect(screen.getByText(/By language/i)).toBeInTheDocument();
    });
    const ptRow = await screen.findByText("PT");
    const enRow = await screen.findByText("EN");
    expect(ptRow).toBeInTheDocument();
    expect(enRow).toBeInTheDocument();
    // pt avg is 50 → formatNumber renders "50.0" (>=10, <100).
    // en avg is 200 → formatNumber renders "200" (>=100, no decimals).
    expect(screen.getAllByText("50.0").length).toBeGreaterThan(0);
    expect(screen.getAllByText("200").length).toBeGreaterThan(0);
  });

  it("falls back to empty state when byLanguage is empty", async () => {
    vi.restoreAllMocks();
    vi.spyOn(global, "fetch").mockImplementation((async (url: string) => {
      const body = url.includes("/summary")
        ? { ...SUMMARY_WITH_LANGS, byLanguage: {} }
        : TIMELINE_EMPTY;
      return new Response(JSON.stringify(body), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as unknown as typeof fetch);
    render(<TelemetryPanel />);
    await waitFor(() => {
      expect(screen.getByText(/By language/i)).toBeInTheDocument();
    });
    expect(
      screen.getByText(/No language-tagged samples yet/i),
    ).toBeInTheDocument();
  });
});
