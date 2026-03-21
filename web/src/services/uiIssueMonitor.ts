export type UiIssueSeverity = "info" | "warning" | "error";

export interface UiIssueEntry {
  id: string;
  scope: string;
  message: string;
  severity: UiIssueSeverity;
  timestamp: number;
  details?: string;
}

const STORAGE_KEY = "epub-to-mp3:ui-issues";
const EVENT_NAME = "epub-to-mp3:ui-issues-updated";
const MAX_ISSUES = 20;

function canUseBrowserApis(): boolean {
  return (
    typeof window !== "undefined" && typeof window.localStorage !== "undefined"
  );
}

function readIssues(): UiIssueEntry[] {
  if (!canUseBrowserApis()) {
    return [];
  }
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) {
      return [];
    }
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as UiIssueEntry[]) : [];
  } catch {
    return [];
  }
}

function writeIssues(issues: UiIssueEntry[]): void {
  if (!canUseBrowserApis()) {
    return;
  }
  try {
    window.localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify(issues.slice(0, MAX_ISSUES)),
    );
    window.dispatchEvent(new CustomEvent(EVENT_NAME));
  } catch {
    // Best effort only.
  }
}

export function reportUiIssue(
  scope: string,
  message: string,
  options: { severity?: UiIssueSeverity; details?: string } = {},
): UiIssueEntry {
  const issue: UiIssueEntry = {
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    scope,
    message,
    severity: options.severity ?? "warning",
    details: options.details,
    timestamp: Date.now(),
  };
  const issues = [issue, ...readIssues()];
  writeIssues(issues);
  return issue;
}

export function dismissUiIssue(id: string): void {
  writeIssues(readIssues().filter((issue) => issue.id !== id));
}

export function clearUiIssues(): void {
  writeIssues([]);
}

export function getUiIssues(): UiIssueEntry[] {
  return readIssues();
}

export function subscribeUiIssues(listener: () => void): () => void {
  if (!canUseBrowserApis()) {
    return () => {};
  }
  const handler = () => listener();
  window.addEventListener(EVENT_NAME, handler);
  return () => window.removeEventListener(EVENT_NAME, handler);
}
