import { screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it } from "vitest";
import UiHealthPanel from "../components/UiHealthPanel";
import { reportUiIssue } from "../services/uiIssueMonitor";
import { renderWithProviders } from "./testUtils";

describe("UiHealthPanel", () => {
  afterEach(() => {
    window.localStorage.clear();
  });

  it("stays hidden by default even when issues are recorded", () => {
    reportUiIssue("reader", "Book text failed to load", {
      severity: "warning",
      details: "job=123",
    });

    const { container } = renderWithProviders(<UiHealthPanel />);

    expect(container).toBeEmptyDOMElement();
  });

  it("renders reported issues only when debug mode is enabled", async () => {
    const user = userEvent.setup();
    window.localStorage.setItem("epub-to-mp3:debug-ui-health", "true");
    reportUiIssue("reader", "Book text failed to load", {
      severity: "warning",
      details: "job=123",
    });
    reportUiIssue("reader", "Book text failed to load", {
      severity: "warning",
      details: "job=123",
    });

    renderWithProviders(<UiHealthPanel />);

    expect(screen.getByText(/Book text failed to load/i)).toBeInTheDocument();
    expect(screen.getAllByText(/Book text failed to load/i)).toHaveLength(1);
    await user.click(screen.getByRole("button", { name: /Limpar avisos/i }));
    expect(
      screen.queryByText(/Book text failed to load/i),
    ).not.toBeInTheDocument();
  });
});
