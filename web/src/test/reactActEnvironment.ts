// React reads this flag before importing the test renderer.
const actEnvironment = { configurable: true, value: true, writable: true };
Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", actEnvironment);
if (typeof window !== "undefined") {
  Object.defineProperty(window, "IS_REACT_ACT_ENVIRONMENT", actEnvironment);
}
