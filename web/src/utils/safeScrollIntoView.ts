function getErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error ?? "");
}

export function isRecoverableScrollError(error: unknown): boolean {
  const message = getErrorMessage(error);
  return /EmptyRanges/i.test(message);
}

export function safeScrollIntoView(
  target: Element | null | undefined,
  options?: ScrollIntoViewOptions,
): void {
  if (!target || typeof target.scrollIntoView !== "function") {
    return;
  }

  try {
    target.scrollIntoView(options);
  } catch (error) {
    if (!isRecoverableScrollError(error)) {
      throw error;
    }
    try {
      target.scrollIntoView({
        block: options?.block ?? "nearest",
        inline: options?.inline ?? "nearest",
      });
    } catch {
      // Ignore browser-specific scroll quirks and keep the UI usable.
    }
  }
}
