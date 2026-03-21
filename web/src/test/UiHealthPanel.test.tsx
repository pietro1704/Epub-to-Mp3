import { screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import UiHealthPanel from "../components/UiHealthPanel";
import { reportUiIssue } from "../services/uiIssueMonitor";
import { renderWithProviders } from "./testUtils";

describe("UiHealthPanel", () => {
  it("renders reported issues and allows clearing them", async () => {
    const user = userEvent.setup();
    reportUiIssue("reader", "Book text failed to load", {
      severity: "warning",
      details: "job=123",
    });

    renderWithProviders(<UiHealthPanel />);

    expect(screen.getByText(/Book text failed to load/i)).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: /Limpar avisos/i }));
    expect(
      screen.queryByText(/Book text failed to load/i),
    ).not.toBeInTheDocument();
  });
});
