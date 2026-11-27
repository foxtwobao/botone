// Localized dates (design §6.6): the row times and thread day separators both format through
// cached Intl formatters in the active UI locale — ports of mobile's formatThreadTime and core's
// formatTimeSeparator, fixture-aligned against the real references (contract/fixtures/dates.json).
import { currentLocale } from './i18n';

/** The date locale for the active UI locale — mobile's dateLocaleForUi (en reads en-US). */
function dateLocale(): string {
  const locale = currentLocale();
  return locale === 'en' ? 'en-US' : locale;
}

/** The hour cycle the reference platform's Intl picks for each shipped locale (CLDR defaults:
 * h12 in English and zh-TW, h23 in zh-CN). The device's own zh-CN default is h12, so the clock
 * is pinned explicitly or the separator clock diverges from every other surface. */
type HourCycle = 'h11' | 'h12' | 'h23' | 'h24';
const HOUR_CYCLES: Record<string, HourCycle> = {};
HOUR_CYCLES['en'] = 'h12' as HourCycle;
HOUR_CYCLES['zh-CN'] = 'h23' as HourCycle;
HOUR_CYCLES['zh-TW'] = 'h12' as HourCycle;

const weekdayFormats: Map<string, Intl.DateTimeFormat> = new Map();
const shortDateFormats: Map<string, Intl.DateTimeFormat> = new Map();
const timeFormats: Map<string, Intl.DateTimeFormat> = new Map();
const fullDateFormats: Map<string, Intl.DateTimeFormat> = new Map();
const fullDateWithYearFormats: Map<string, Intl.DateTimeFormat> = new Map();

/** The full-date option set with the locale's pinned hour cycle folded in. */
function fullDateOptions(withYear: boolean): Intl.DateTimeFormatOptions {
  const cycle: HourCycle = HOUR_CYCLES[currentLocale()] ?? 'h12';
  if (withYear) {
    return { month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit', hourCycle: cycle };
  }
  return { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', hourCycle: cycle };
}

/** Calendar-day equality in the viewer's zone. */
function sameYear(date: Date, now: number): boolean {
  return date.getFullYear() === new Date(now).getFullYear();
}

function formatter(cache: Map<string, Intl.DateTimeFormat>, locale: string, options: Intl.DateTimeFormatOptions,
  cacheKey?: string): Intl.DateTimeFormat {
  const key = cacheKey ?? locale;
  let format = cache.get(key);
  if (format === undefined) {
    format = new Intl.DateTimeFormat(locale, options);
    cache.set(key, format);
  }
  return format;
}

function weekdayFormat(locale: string): Intl.DateTimeFormat {
  return formatter(weekdayFormats, locale, { weekday: 'long' });
}

function shortDateFormat(locale: string): Intl.DateTimeFormat {
  return formatter(shortDateFormats, locale, { month: 'short', day: 'numeric' });
}

function clockTime(date: Date): string {
  const cycle: HourCycle = HOUR_CYCLES[currentLocale()] ?? 'h12';
  const options: Intl.DateTimeFormatOptions = { hour: 'numeric', minute: '2-digit', hourCycle: cycle };
  return formatter(timeFormats, dateLocale(), options, `${dateLocale()}#${cycle}`).format(date);
}

/** Row time, ported from mobile formatThreadTime: today a localized clock, the past week a
 * weekday name, older a short date. */
export function formatRowTime(iso: string, now: number): string {
  const date = new Date(iso);
  const time = date.getTime();
  if (Number.isNaN(time)) {
    return '';
  }
  const startOfDay = (d: Date): number => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const dayDiff = Math.round((startOfDay(new Date(now)) - startOfDay(date)) / 86_400_000);
  if (dayDiff <= 0) {
    return clockTime(date);
  }
  const locale = dateLocale();
  if (dayDiff < 7) {
    return weekdayFormat(locale).format(date);
  }
  return shortDateFormat(locale).format(date);
}

/** Thread day separator, ported from core formatTimeSeparator: Today/Yesterday + clock, the past
 * week a weekday + clock, older a short date with the year only when it differs from now's. The
 * today/yesterday labels arrive translated (the shared msgids). */
export function formatThreadSeparator(iso: string, now: number, today: string, yesterday: string): string {
  const date = new Date(iso);
  const time = date.getTime();
  if (Number.isNaN(time)) {
    return '';
  }
  const clock = clockTime(date);
  const startOfDay = (d: Date): number => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const dayDiff = Math.round((startOfDay(new Date(now)) - startOfDay(date)) / 86_400_000);
  if (dayDiff <= 0) {
    return `${today} ${clock}`;
  }
  if (dayDiff === 1) {
    return `${yesterday} ${clock}`;
  }
  const locale = dateLocale();
  if (dayDiff < 7) {
    return `${weekdayFormat(locale).format(date)} ${clock}`;
  }
  // Two caches, not one: the same-year and different-year patterns differ under the same locale.
  const cycle: HourCycle = HOUR_CYCLES[currentLocale()] ?? 'h12';
  const cacheKey = `${locale}#${cycle}`;
  if (sameYear(date, now)) {
    return formatter(fullDateFormats, locale, fullDateOptions(false), cacheKey).format(date);
  }
  return formatter(fullDateWithYearFormats, locale, fullDateOptions(true), cacheKey).format(date);
}
