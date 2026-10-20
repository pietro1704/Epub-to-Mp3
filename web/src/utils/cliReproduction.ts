import type { CliShell, ConversionFormValues, TtsSelection } from "../types/conversion";

const supportedFields = new Set([
  "file", "fileName", "localPath", "uploadId", "bookTitle", "bookAuthor",
  "coverUrl", "uiLanguage", "engine", "voice", "model", "tts_preferences",
  "chapters", "sections", "noParallel", "clearCache", "footnoteMode",
]);

function validSelection(value: TtsSelection | null | undefined): boolean {
  if (!value || typeof value !== "object") return false;
  if (Object.keys(value).some(key => !["engine", "model_id", "voice"].includes(key))) return false;
  if (value.engine === "piper") {
    const model = value.model_id;
    return typeof model === "string" && model.length > 0 &&
      !/[\\/]/.test(model) && model !== "." && model !== ".." && value.voice === null;
  }
  return value.engine === "edge" && value.model_id === null &&
    (value.voice === null || typeof value.voice === "string");
}

/** Render only captured jobs with a local source and faithfully representable options. */
export function buildCliReproduction(values: ConversionFormValues): { command: string; shell: CliShell } | undefined {
  const source = values.localPath;
  if (!source || source.includes("\u0000") || source.includes("\r") ||
      source.includes("\n") || !/\.(epub|pdf)$/i.test(source)) return undefined;
  const windows = /^[A-Za-z]:[\\/]/.test(source) || /^\\\\[^\\]+\\[^\\]+/.test(source);
  if (!windows && !source.startsWith("/")) return undefined;
  if (values.footnoteMode !== "inline" || values.sections?.trim() || values.clearCache) return undefined;
  if (Object.entries(values).some(([key, value]) => value !== undefined && !supportedFields.has(key))) return undefined;
  // Legacy engine/voice/model fields are form state; routing uses the captured policy.
  const preferences = values.tts_preferences;
  if (!preferences || !validSelection(preferences.primary) ||
      typeof preferences.allow_online_fallback !== "boolean" ||
      Object.keys(preferences).some(key => !["primary", "secondary", "allow_online_fallback"].includes(key))) return undefined;
  const secondary = preferences.secondary;
  if (secondary !== null && (!validSelection(secondary) ||
      (secondary.engine === "edge" && !preferences.allow_online_fallback) ||
      (secondary.engine === preferences.primary.engine &&
       secondary.model_id === preferences.primary.model_id &&
       secondary.voice === preferences.primary.voice))) return undefined;

  const quote = windows
    ? (value: string) => "'" + value.replace(/'/g, "''") + "'"
    : (value: string) => "'" + value.replace(/'/g, "'\\''") + "'";
  const parts = [
    windows ? "& converter-cli" : "converter-cli",
    "convert",
    quote(source),
    "--tts-preferences-json",
    quote(JSON.stringify(preferences)),
  ];
  // Browser ordinals are 1-based; Rust CLI positions are explicitly zero-based.
  if (values.chapters?.trim()) {
    const range = /^(\d+)(?:-(\d+))?$/.exec(values.chapters.trim());
    if (!range) return undefined;
    const first = Number(range[1]);
    const last = Number(range[2] ?? range[1]);
    // Bound rendering only; a long selection still converts through the app.
    if (!Number.isSafeInteger(first) || !Number.isSafeInteger(last) ||
        first < 1 || last < first || last - first >= 512) return undefined;
    for (let ordinal = first; ordinal <= last; ordinal += 1) {
      parts.push("--chapter", quote("position:" + (ordinal - 1)));
    }
  }
  if (values.noParallel) parts.push("--no-parallel");
  return { command: parts.join(" "), shell: windows ? "PowerShell" : "Bash/Zsh" };
}
