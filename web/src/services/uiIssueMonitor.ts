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
const DEBUG_PANEL_KEY = "epub-to-mp3:debug-ui-health";
const MAX_ISSUES = 20;
const DEDUPE_WINDOW_MS = 30_000;

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

function logUiIssue(issue: UiIssueEntry): void {
  const method =
    issue.severity === "error"
      ? console.error
      : issue.severity === "warning"
        ? console.warn
        : console.info;
  method(`[ui:${issue.scope}] ${issue.message}`, issue.details ?? "");
}

function findRecentDuplicate(
  issue: UiIssueEntry,
  issues: UiIssueEntry[],
): UiIssueEntry | null {
  return (
    issues.find(
      (entry) =>
        entry.scope === issue.scope &&
        entry.message === issue.message &&
        entry.details === issue.details &&
        issue.timestamp - entry.timestamp <= DEDUPE_WINDOW_MS,
    ) ?? null
  );
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
  const existingIssues = readIssues();
  const duplicate = findRecentDuplicate(issue, existingIssues);
  if (duplicate) {
    return duplicate;
  }
  logUiIssue(issue);
  const issues = [issue, ...existingIssues];
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

export function shouldShowUiHealthPanel(): boolean {
  if (!canUseBrowserApis()) {
    return false;
  }
  return window.localStorage.getItem(DEBUG_PANEL_KEY) === "true";
}

export function subscribeUiIssues(listener: () => void): () => void {
  if (!canUseBrowserApis()) {
    return () => {};
  }
  const handler = () => listener();
  window.addEventListener(EVENT_NAME, handler);
  return () => window.removeEventListener(EVENT_NAME, handler);
}
