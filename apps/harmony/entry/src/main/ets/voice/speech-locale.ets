// Speech locales (M7): a port of core's calls/speech-locale.ts. Recognizers and synthesizers name
// countries, not languages, so the app's UI locale becomes a regional tag, and a recognizer that
// lists the tags it starts is asked for the closest one. Pure; the layer-2 voice fixture is
// generated from the real core module.

const SPEECH_LOCALE_TAGS: Record<string, string> = {};
SPEECH_LOCALE_TAGS['en'] = 'en-US';
SPEECH_LOCALE_TAGS['de'] = 'de-DE';
SPEECH_LOCALE_TAGS['es'] = 'es-ES';
SPEECH_LOCALE_TAGS['fr'] = 'fr-FR';
SPEECH_LOCALE_TAGS['he'] = 'he-IL';
SPEECH_LOCALE_TAGS['hi'] = 'hi-IN';
SPEECH_LOCALE_TAGS['ja'] = 'ja-JP';
SPEECH_LOCALE_TAGS['ko'] = 'ko-KR';
SPEECH_LOCALE_TAGS['nl'] = 'nl-NL';
SPEECH_LOCALE_TAGS['pl'] = 'pl-PL';
SPEECH_LOCALE_TAGS['pt-BR'] = 'pt-BR';
SPEECH_LOCALE_TAGS['ru'] = 'ru-RU';
SPEECH_LOCALE_TAGS['th'] = 'th-TH';
SPEECH_LOCALE_TAGS['tr'] = 'tr-TR';
SPEECH_LOCALE_TAGS['zh-CN'] = 'zh-CN';
SPEECH_LOCALE_TAGS['zh-TW'] = 'zh-TW';

/** Recognizers name countries, not Latin America as a whole: Mexico's Spanish is its default. */
const LATIN_AMERICAN_SPANISH = 'es-MX';

export function speechLocaleTag(locale: string): string {
  return SPEECH_LOCALE_TAGS[locale] ?? locale;
}

/**
 * English UI follows the device language, regardless of shipped catalogs. Other UI languages use
 * the speaker's region when the language matches; Chinese keeps the app's tag to preserve its
 * script. Known languages without a region use the shared default for that language.
 */
export function recognitionLocaleTag(locale: string, speaker: string | null | undefined): string {
  const appTag = speechLocaleTag(locale);
  const normalized = speakerTag(speaker);
  const spoken = normalized === 'es-419' ? LATIN_AMERICAN_SPANISH : normalized;
  if (spoken === null || locale.startsWith('zh')) {
    return appTag;
  }
  const parts = spoken.split('-');
  const language = parts[0] ?? '';
  const region = parts[1];
  if (locale !== 'en' && language !== (appTag.split('-')[0] ?? '')) {
    return appTag;
  }
  if (region !== undefined && region !== '') {
    return spoken;
  }
  const tags = Object.keys(SPEECH_LOCALE_TAGS).map((key: string): string => SPEECH_LOCALE_TAGS[key] ?? '');
  return tags.find((tag: string): boolean => tag.startsWith(`${language}-`)) ?? spoken;
}

/** `es_ar`, `en-US-u-mu-celsius`, `zh-Hant-TW` → `es-AR`, `en-US`, `zh-TW`. */
function speakerTag(raw: string | null | undefined): string | null {
  const source = raw !== null && raw !== undefined ? raw.trim().replace(/_/g, '-') : '';
  const match = /^([a-z]{2,3})(?:-[a-z]{4})?(?:-([a-z]{2}|\d{3}))?(?:-|$)/i.exec(source);
  if (match === null) {
    return null;
  }
  const language = (match[1] ?? '').toLowerCase();
  const region = match[2];
  const upper = region !== undefined ? region.toUpperCase() : '';
  return upper !== '' ? `${language}-${upper}` : language;
}

/**
 * The tag in `supported` closest to `wanted`: a phone's language and region (`es-AR`, `en-DE`) is
 * often not one a recognizer starts. Falls back to the region the app uses for that language,
 * then to any region of it. An empty list means the recognizer does not say, so `wanted` stays.
 */
export function supportedSpeechTag(wanted: string, supported: string[]): string {
  const key = (tag: string): string => speakerTag(tag)?.toLowerCase() ?? '';
  const parts = key(wanted).split('-');
  const language = parts[0] ?? '';
  const region = parts[1];
  const tags = Object.keys(SPEECH_LOCALE_TAGS).map((name: string): string => SPEECH_LOCALE_TAGS[name] ?? '');
  const home = language === 'es' && region !== undefined && region !== '' && region !== 'es'
    ? LATIN_AMERICAN_SPANISH
    : tags.find((tag: string): boolean => key(tag).startsWith(`${language}-`));
  const exact = supported.find((tag: string): boolean => key(tag) === key(wanted));
  if (exact !== undefined) {
    return exact;
  }
  const regional = supported.find((tag: string): boolean => key(tag) === key(home ?? ''));
  if (regional !== undefined) {
    return regional;
  }
  const sorted = [...supported].sort();
  const anyRegion = sorted.find((tag: string): boolean => (key(tag).split('-')[0] ?? '') === language);
  return anyRegion ?? wanted;
}
