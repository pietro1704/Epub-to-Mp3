export const READER_PREFS_KEY = "epub-to-mp3:reader-prefs"
export const DEFAULT_READER_PREFS = Object.freeze({
  fontScale: 1.05, lineHeight: 1.75, widthRem: 48,
  theme: "paper", followAudio: true, fontFamily: "serif",
})

/** Validate the persisted UI controls; document layout itself belongs to Rust. */
export function readerPreferences(value = {}) {
  const number = (key, min, max) => typeof value[key] === "number" && Number.isFinite(value[key])
    ? Math.max(min, Math.min(max, value[key])) : DEFAULT_READER_PREFS[key]
  return {
    fontScale: number("fontScale", 0.9, 1.4),
    lineHeight: number("lineHeight", 1.45, 2.1),
    widthRem: number("widthRem", 34, 68),
    theme: ["paper", "mist", "ink"].includes(value.theme) ? value.theme : "paper",
    fontFamily: ["serif", "sans"].includes(value.fontFamily) ? value.fontFamily : "serif",
    followAudio: typeof value.followAudio === "boolean" ? value.followAudio : true,
  }
}

export function loadReaderPreferences(storage) {
  try { return readerPreferences(JSON.parse(storage.getItem(READER_PREFS_KEY)) ?? {}) }
  catch { return { ...DEFAULT_READER_PREFS } }
}

export function saveReaderPreferences(storage, preferences) {
  try { storage.setItem(READER_PREFS_KEY, JSON.stringify(preferences)) }
  catch { /* Reading still works when local storage is unavailable. */ }
}
