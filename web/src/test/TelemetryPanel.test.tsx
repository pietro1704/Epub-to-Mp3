import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  vi,
  type MockInstance,
} from "vitest";
import TelemetryPanel, {
  DEFAULT_TELEMETRY_LABELS_EN,
} from "../components/TelemetryPanel";
import { renderWithProviders } from "./testUtils";

const summaryResponse = {
  engines: {
    edge: {
      samples: 12,
      avg_chars_per_second: 210.5,
      max_chars_per_second: 260.0,
      min_chars_per_second: 150.0,
    },
    piper: {
      samples: 4,
      avg_chars_per_second: 80.0,
      max_chars_per_second: 95.0,
      min_chars_per_second: 60.0,
    },
  },
  ranked: ["edge", "piper"],
  totalSamples: 16,
};

const timelineResponse = {
  points: [
    {
      engine: "edge",
      voice: "pt-BR-A",
      timestamp: "2026-04-15T10:00:00Z",
      charsPerSecond: 200.0,
      chars: 1000,
      synthSeconds: 5.0,
      chapter: "Chapter 1",
      jobId: "job-1",
    },
    {
      engine: "piper",
      voice: null,
      timestamp: "2026-04-15T10:05:00Z",
      charsPerSecond: 83.0,
      chars: 500,
      synthSeconds: 6.0,
      chapter: "Chapter 2",
      jobId: "job-1",
    },
  ],
  count: 2,
};

function makeResponse(body: unknown, ok = true, status = 200): Response {
  return {
    ok,
    status,
    statusText: ok ? "OK" : "Error",
    json: async () => body,
  } as unknown as Response;
}

describe("TelemetryPanel", () => {
  let fetchMock: MockInstance;

  beforeEach(() => {
    fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockImplementation(async (input: RequestInfo | URL) => {
        const url = typeof input === "string" ? input : input.toString();
        if (url.includes("/api/telemetry/summary")) {
          return makeResponse(summaryResponse);
        }
        if (url.includes("/api/telemetry/timeline")) {
          return makeResponse(timelineResponse);
        }
        return makeResponse({}, false, 404);
      });
  });

  afterEach(() => {
    fetchMock.mockRestore();
    vi.clearAllMocks();
  });

  it("renders engine rows sorted by ranked order", async () => {
    renderWithProviders(
      <TelemetryPanel labels={DEFAULT_TELEMETRY_LABELS_EN} autoRefreshMs={0} />,
    );

    await waitFor(() => {
      expect(screen.getAllByText("EDGE").length).toBeGreaterThan(0);
    });
    expect(screen.getAllByText("PIPER").length).toBeGreaterThan(0);
    // 210.5.toFixed(0) → "211" (banker's rounding)
    expect(screen.getByText("211")).toBeInTheDocument();
    // Piper avg 80.0 → "80.0" (>=10 rounds to 1 decimal)
    expect(screen.getByText("80.0")).toBeInTheDocument();
    expect(screen.getByText(/16 total samples/i)).toBeInTheDocument();
    expect(screen.getByText(/EDGE → PIPER/)).toBeInTheDocument();
  });

  it("renders timeline entries", async () => {
    renderWithProviders(
      <TelemetryPanel labels={DEFAULT_TELEMETRY_LABELS_EN} autoRefreshMs={0} />,
    );

    await waitFor(() => {
      expect(screen.getByText("Chapter 1")).toBeInTheDocument();
    });
    expect(screen.getByText("Chapter 2")).toBeInTheDocument();
    expect(screen.getByText("1000 chars")).toBeInTheDocument();
  });

  it("shows empty state when no engines reported", async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = typeof input === "string" ? input : input.toString();
      if (url.includes("/api/telemetry/summary")) {
        return makeResponse({ engines: {}, ranked: [], totalSamples: 0 });
      }
      return makeResponse({ points: [], count: 0 });
    });

    renderWithProviders(
      <TelemetryPanel labels={DEFAULT_TELEMETRY_LABELS_EN} autoRefreshMs={0} />,
    );

    await waitFor(() => {
      expect(
        screen.getByText(DEFAULT_TELEMETRY_LABELS_EN.emptyState),
      ).toBeInTheDocument();
    });
  });

  it("shows error banner on fetch failure", async () => {
    fetchMock.mockImplementation(async () => makeResponse({}, false, 500));

    renderWithProviders(
      <TelemetryPanel labels={DEFAULT_TELEMETRY_LABELS_EN} autoRefreshMs={0} />,
    );

    await waitFor(() => {
      expect(screen.getByRole("alert")).toBeInTheDocument();
    });
  });

  it("falls back to English defaults when no labels prop is given", async () => {
    renderWithProviders(<TelemetryPanel autoRefreshMs={0} />);

    await waitFor(() => {
      expect(
        screen.getByText(DEFAULT_TELEMETRY_LABELS_EN.title),
      ).toBeInTheDocument();
    });
    expect(
      screen.getByText(DEFAULT_TELEMETRY_LABELS_EN.timelineTitle),
    ).toBeInTheDocument();
  });

  it("refreshes when the button is clicked", async () => {
    const user = userEvent.setup();
    renderWithProviders(
      <TelemetryPanel labels={DEFAULT_TELEMETRY_LABELS_EN} autoRefreshMs={0} />,
    );

    await waitFor(() => {
      expect(screen.getAllByText("EDGE").length).toBeGreaterThan(0);
    });

    // Initial load: summary + timeline = 2 fetches
    expect(fetchMock).toHaveBeenCalledTimes(2);

    await user.click(
      screen.getByRole("button", { name: DEFAULT_TELEMETRY_LABELS_EN.refresh }),
    );

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledTimes(4);
    });
  });
});
