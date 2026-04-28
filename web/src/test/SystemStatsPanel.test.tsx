import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import SystemStatsPanel from "../components/SystemStatsPanel";
import type { SystemStats } from "../hooks/useSystemStats";

const labels = {
  title: "System monitoring",
  loading: "Collecting metrics…",
  error: "Could not load metrics.",
  offline: "Backend unreachable.",
  uptime: "Uptime",
  cpu: "CPU",
  memory: "Memory",
  queue: "Queue",
  running: "Running",
  workers: "Workers",
  recommendation: "Recommendation",
  gpu: "GPUs",
  lastUpdated: (value: string) => `Updated ${value}`,
  retrying: (value: string) => `Retrying in ${value}`,
  target: "Target",
  gpuUsage: "Usage",
  gpuVram: "VRAM",
  gpuTemp: "Temp",
};

describe("SystemStatsPanel", () => {
  it("renders the loading placeholder when stats are null", () => {
    render(<SystemStatsPanel stats={null} labels={labels} isLoading />);
    expect(screen.getByText("System monitoring")).toBeInTheDocument();
    expect(screen.getByText("Collecting metrics…")).toBeInTheDocument();
  });

  it("renders the offline placeholder when stats are null and hasError", () => {
    render(
      <SystemStatsPanel
        stats={null}
        labels={labels}
        hasError
        nextRetryMs={5000}
      />,
    );
    expect(screen.getByText("Backend unreachable.")).toBeInTheDocument();
    expect(screen.getByText("Could not load metrics.")).toBeInTheDocument();
    expect(screen.getByText(/Retrying in 5s/)).toBeInTheDocument();
  });

  it("renders CPU, memory and queue when stats are populated", () => {
    const stats: SystemStats = {
      timestamp: Date.now(),
      uptimeSeconds: 3700,
      cpu: { percent: 42 },
      memory: {
        percent: 55,
        used: 8 * 1024 * 1024 * 1024,
        total: 16 * 1024 * 1024 * 1024,
      },
      jobs: { queueDepth: 3, inFlight: 1, workers: { current: 2, target: 4 } },
      recommendations: { parallelSlots: 6, jobWorkers: 4 },
    } as SystemStats;
    render(<SystemStatsPanel stats={stats} labels={labels} />);
    expect(screen.getByText("42%")).toBeInTheDocument();
    expect(screen.getByText("55%")).toBeInTheDocument();
    expect(screen.getByText("3")).toBeInTheDocument();
    expect(screen.getByText(/Target:/)).toBeInTheDocument();
    expect(screen.getByText(/Uptime: 1h 1m/)).toBeInTheDocument();
  });

  it("renders GPU labels using i18n strings (no hardcoded Portuguese)", () => {
    const stats: SystemStats = {
      timestamp: Date.now(),
      gpus: [
        {
          name: "RTX 4090",
          utilizationPercent: 73,
          memoryUsedMB: 4096,
          memoryTotalMB: 24576,
          temperatureC: 65,
        },
      ],
    } as SystemStats;
    render(<SystemStatsPanel stats={stats} labels={labels} />);
    expect(screen.getByText("RTX 4090")).toBeInTheDocument();
    expect(screen.getByText(/Usage: 73%/)).toBeInTheDocument();
    expect(screen.getByText(/VRAM: 4096 \/ 24576 MB/)).toBeInTheDocument();
    expect(screen.getByText(/Temp: 65°C/)).toBeInTheDocument();
    expect(screen.queryByText(/Uso:/)).not.toBeInTheDocument();
  });
});
