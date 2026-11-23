// Catalog runtime (design §6.6): the codegen JSON (msgid → msgstr) loads from rawfile once;
// t() looks up and evaluates ICU-lite. A missing translation falls back to the msgid — the
// English source string — exactly like lingui. Phase 1 ships en / zh-CN / zh-TW.
import { common } from '@kit.AbilityKit';
import { i18n as systemI18n } from '@kit.LocalizationKit';
import { util } from '@kit.ArkTS';
import { formatIcu } from './icu';

let catalog: Record<string, string> = {};
let activeLocale: string = 'en';

export function currentLocale(): string {
  return activeLocale;
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

export async function loadI18n(context: common.Context): Promise<void> {
  activeLocale = resolveLocale(systemI18n.System.getSystemLocale());
  try {
    const bytes = await context.resourceManager.getRawFileContent(`i18n/${activeLocale}.json`);
    const text = util.TextDecoder.create('utf-8').decodeToString(bytes);
    const parsed = JSON.parse(text) as Record<string, string>;
    catalog = parsed;
  } catch (err) {
    // Without the codegen output every string falls back to its English source; the app still runs.
    catalog = {};
  }
}

export function t(msgid: string, values?: Record<string, string | number>): string {
  const message = catalog[msgid] ?? msgid;
  if (values === undefined) {
    return message.includes('{') ? formatIcu(message, {}, activeLocale) : message;
  }
  return formatIcu(message, values, activeLocale);
}
