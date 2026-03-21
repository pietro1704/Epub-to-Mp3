import "@testing-library/jest-dom/vitest";
import { afterAll, afterEach, beforeAll, vi } from "vitest";
import { cleanup } from "@testing-library/react";

// Suppress React act() warnings in tests
const originalError = console.error;
beforeAll(() => {
  console.error = (...args: unknown[]) => {
    const first = args[0];
    if (
      typeof first === "string" &&
      first.includes("Warning: An update to") &&
      first.includes("was not wrapped in act")
    ) {
      return;
    }
    originalError.call(console, ...args);
  };
});

afterAll(() => {
  console.error = originalError;
});

if (typeof window !== "undefined") {
  const storageState = new Map<string, string>();
  const localStorageMock: Storage = {
    get length() {
      return storageState.size;
    },
    clear() {
      storageState.clear();
    },
    getItem(key: string) {
      return storageState.has(key) ? (storageState.get(key) ?? null) : null;
    },
    key(index: number) {
      return Array.from(storageState.keys())[index] ?? null;
    },
    removeItem(key: string) {
      storageState.delete(key);
    },
    setItem(key: string, value: string) {
      storageState.set(String(key), String(value));
    },
  };

  Object.defineProperty(window, "localStorage", {
    configurable: true,
    value: localStorageMock,
  });

  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: localStorageMock,
  });
}

if (typeof window !== "undefined" && !window.matchMedia) {
  Object.defineProperty(window, "matchMedia", {
    writable: true,
    value: vi.fn().mockImplementation((query: string) => ({
      matches: false,
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn(),
    })),
  });
}

if (typeof window !== "undefined" && typeof window.confirm !== "function") {
  window.confirm = () => true;
}

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
