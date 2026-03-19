import type { ConversionState } from "../types/conversion";
import type { Locale, Translations } from "../i18n/translations";

export function formatEta(
  phase: ConversionState["phase"],
  etaSeconds: number | null | undefined,
  locale: Locale,
  t: Translations,
): string {
  if (phase === "success") {
    return t.status.etaDone;
  }
  if (phase === "error" || phase === "cancelled") {
    return "—";
  }
  if (phase === "idle") {
    return "—";
  }
  if (typeof etaSeconds !== "number") {
    return t.status.etaCalculating;
  }
  if (etaSeconds <= 1) {
    return t.status.etaSoon;
  }
  const totalSeconds = Math.max(0, Math.round(etaSeconds));
  const units: Array<{ label: string; value: number }> = [
    { label: "d", value: 86400 },
    { label: "h", value: 3600 },
    { label: "m", value: 60 },
    { label: "s", value: 1 },
  ];
  let remainder = totalSeconds;
  const parts: string[] = [];
  for (const unit of units) {
    const qty = Math.floor(remainder / unit.value);
    if (qty > 0) {
      parts.push(`${qty}${unit.label}`);
      remainder -= qty * unit.value;
    }
    if (parts.length >= 2) {
      break;
    }
  }
  if (parts.length === 0) {
    parts.push("0s");
  }
  const humanEta = parts.join(" ");
  return locale === "pt" ? `≈ ${humanEta}` : `≈ ${humanEta}`;
}
