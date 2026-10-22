import type { Locale, Translations } from './translation_contract';
import { pt_conversion } from './pt_conversion';
import { pt_library } from './pt_library';
import { pt_runtime_layout } from './pt_runtime_layout';
import { pt_conversion_status } from './pt_conversion_status';
import { pt_application } from './pt_application';
import { en_conversion } from './en_conversion';
import { en_library } from './en_library';
import { en_runtime_layout } from './en_runtime_layout';
import { en_conversion_status } from './en_conversion_status';
import { en_application } from './en_application';
export type * from './translation_conversion_types';
export type * from './translation_status_types';
export type * from './translation_layout_types';
export type * from './translation_contract';

export const translations: Record<Locale, Translations> = {
  pt: { ...pt_conversion, ...pt_library, ...pt_runtime_layout, ...pt_conversion_status, ...pt_application },
  en: { ...en_conversion, ...en_library, ...en_runtime_layout, ...en_conversion_status, ...en_application },
};

export function resolveLocale(input?: string | null): Locale {
  if (!input) return 'en';
  const normalised = input.toLowerCase();
  if (normalised.startsWith('pt')) return 'pt';
  return 'en';
}

export function getTranslations(locale: Locale): Translations {
  return translations[locale];
}
