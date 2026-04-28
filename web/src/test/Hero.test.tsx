import { screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import Hero from "../components/Hero";
import { renderWithProviders } from "./testUtils";

describe("Hero", () => {
  it("renders nothing when phase is idle and there is no metadata", () => {
    const { container } = renderWithProviders(<Hero phase="idle" />);
    expect(container).toBeEmptyDOMElement();
  });

  it("renders book metadata when title is provided", () => {
    renderWithProviders(
      <Hero
        phase="polling"
        title="Conversion Title"
        author="A. Author"
        summary={{ chaptersCompleted: 2, chaptersTotal: 8 }}
        etaSeconds={120}
        engineLabel="edge"
        voiceLabel="pt-BR-A"
        languageLabel="pt-BR"
      />,
    );
    // The Hero renders two views (expanded + collapsed) — title shows in both.
    expect(screen.getAllByText("Conversion Title").length).toBeGreaterThan(0);
    expect(screen.getByText("A. Author")).toBeInTheDocument();
    expect(screen.getByText("2/8")).toBeInTheDocument();
    expect(screen.getByText("edge")).toBeInTheDocument();
    expect(screen.getByText("pt-BR-A")).toBeInTheDocument();
    expect(screen.getByText("pt-BR")).toBeInTheDocument();
  });

  it("renders the progress bar with computed percentage", () => {
    renderWithProviders(
      <Hero
        phase="polling"
        title="Book"
        summary={{ chaptersCompleted: 3, chaptersTotal: 6 }}
      />,
    );
    const bars = screen.getAllByRole("progressbar");
    expect(bars[0].getAttribute("aria-valuenow")).toBe("50");
    expect(screen.getAllByText(/50\.0%/).length).toBeGreaterThan(0);
  });

  it("renders queue position pill when queueTotal > 1", () => {
    renderWithProviders(
      <Hero phase="polling" title="Book" queuePosition={2} queueTotal={5} />,
    );
    expect(screen.getByText(/· 2\/5/)).toBeInTheDocument();
  });
});
