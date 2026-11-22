// Catalog runtime (design §6.6): the codegen JSON (msgid → msgstr) loads from rawfile; t() looks
// up and evaluates ICU-lite. A missing translation falls back to the msgid — the English source
// string — exactly like lingui. Phase 1 ships en / zh-CN / zh-TW. The locale preference (system /
// en / zh-CN / zh-TW) persists in preferences; System re-resolves from the device locale, including
// when the system language changes while the app runs. The store is @ObservedV2 so a locale switch
// re-renders every screen whose build() calls t() (the same tracking appearance.tokens() uses).
import { common } from '@kit.AbilityKit';
import { i18n as systemI18n } from '@kit.LocalizationKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { formatIcu } from './icu';

const PREFS_NAME = 'rakazo.i18n';
const PREF_KEY = 'rakazo.uiLocale';

/** The locales Phase 1 ships catalogs for, in the order the picker lists them. */
export const SHIPPED_LOCALES: string[] = ['en', 'zh-CN', 'zh-TW'];

/** system | en | zh-CN | zh-TW. */
export function isLocalePreference(value: string): boolean {
  return value === 'system' || SHIPPED_LOCALES.includes(value);
}

/** System locale → a shipped catalog; anything else reads English. */
export function resolveLocale(systemLocale: string): string {
  const lower = systemLocale.toLowerCase();
  if (lower.startsWith('zh')) {
    return lower.includes('hant') || lower.includes('-tw') || lower.includes('-hk') || lower.includes('-mo')
      ? 'zh-TW'
      : 'zh-CN';
  }
  return 'en';
}

/** The device locale tag via the non-deprecated instance API (getSystemLocale is deprecated). */
function systemLocaleTag(): string {
  return systemI18n.System.getSystemLocaleInstance().toString();
}

@ObservedV2
export class I18nStore {
  /** The resolved catalog locale (en / zh-CN / zh-TW). */
  @Trace locale: string = 'en';
  /** The user's choice: system or a shipped locale. */
  @Trace preference: string = 'system';
  /** Bumped on every catalog load so build()s that call t() re-render even when the locale label
   * is unchanged (a same-locale reload still swaps the catalog object). */
  @Trace revision: number = 0;
  private catalog: Record<string, string> = {};
  private context: common.Context | null = null;
  private store: preferences.Preferences | null = null;
  private lastSystemLocale: string = '';

  /** The catalog message for a msgid, falling back to the English source string (lingui parity). */
  message(msgid: string): string {
    // Reading the traced revision registers the dependency: a locale switch re-renders the
    // calling build() even when the resolved locale label is unchanged.
    void this.revision;
    return this.catalog[msgid] ?? msgid;
  }

  async init(context: common.Context): Promise<void> {
    this.context = context;
    try {
      this.store = await preferences.getPreferences(context, PREFS_NAME);
      const stored = await this.store.get(PREF_KEY, 'system');
      if (typeof stored === 'string' && isLocalePreference(stored as string)) {
        this.preference = stored as string;
      }
    } catch (err) {
      // Without a readable store the in-memory preference (system) still applies.
    }
    await this.apply();
  }

  /** A manual choice from the settings screen: persist, resolve, reload the catalog. */
  async setPreference(preference: string): Promise<void> {
    if (!isLocalePreference(preference)) {
      return;
    }
    this.preference = preference;
    if (this.store !== null) {
      try {
        await this.store.put(PREF_KEY, preference);
        await this.store.flush();
      } catch (err) {
        // The in-memory preference still applies when the write fails.
      }
    }
    await this.apply();
  }

  /** The system locale changed while running: re-resolve only when the choice is System and the
   * device locale actually moved (a color-mode change also fires onConfigurationUpdate). */
  async systemLocaleChanged(): Promise<void> {
    if (this.preference !== 'system') {
      return;
    }
    const systemLocale = systemLocaleTag();
    if (systemLocale === this.lastSystemLocale) {
      return;
    }
    this.lastSystemLocale = systemLocale;
    await this.apply();
  }

  private resolvedLocale(): string {
    return this.preference === 'system'
      ? resolveLocale(systemLocaleTag())
      : this.preference;
  }

  private async apply(): Promise<void> {
    this.lastSystemLocale = systemLocaleTag();
    const locale = this.resolvedLocale();
    let catalog: Record<string, string> = {};
    if (this.context !== null) {
      try {
        const bytes = await this.context.resourceManager.getRawFileContent(`i18n/${locale}.json`);
        const text = util.TextDecoder.create('utf-8').decodeToString(bytes);
        catalog = JSON.parse(text) as Record<string, string>;
      } catch (err) {
        // Without the codegen output every string falls back to its English source; the app runs.
        catalog = {};
      }
    }
    this.catalog = catalog;
    this.locale = locale;
    this.revision += 1;
  }
}

export const i18nStore: I18nStore = new I18nStore();

export function currentLocale(): string {
  return i18nStore.locale;
}

/** The locale preference for the settings picker (system / en / zh-CN / zh-TW). */
export function localePreference(): string {
  return i18nStore.preference;
}

export async function loadI18n(context: common.Context): Promise<void> {
  await i18nStore.init(context);
}

export async function setLocalePreference(preference: string): Promise<void> {
  await i18nStore.setPreference(preference);
}

export function t(msgid: string, values?: Record<string, string | number>): string {
  const message = i18nStore.message(msgid);
  const locale = i18nStore.locale;
  if (values === undefined) {
    return message.includes('{') ? formatIcu(message, {}, locale) : message;
  }
  return formatIcu(message, values, locale);
}
