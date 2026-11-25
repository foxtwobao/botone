// Bot voices (M7): a port of mobile's lib/voice/bot-voices.ts, the choice itself. Each bot is
// handed a voice of the device's language no other bot has yet (the device engine lists which
// ones are installed), preferring the device's own region, then the language's main region, then
// any; an unused voice before a shared one, a higher-quality one before the rest. Pure: the
// listing and the saved assignments arrive as arguments, so the layer-2 voice fixture (generated
// from the real mobile module) replays it. Not ported: voiceLabel (the per-bot picker arrives
// with the bot settings page).
import { pickUnusedVoice } from './voice-assignment';

/** A voice the device lists, as the choice reads it. */
export interface ListedVoice {
  identifier: string;
  language: string;
  name?: string;
  quality?: string;
  localService?: boolean;
  requiresNetwork?: boolean;
}

function isNetworkVoice(voice: ListedVoice): boolean {
  if (voice.requiresNetwork === true) {
    return true;
  }
  if (voice.localService === false) {
    return true;
  }
  return /network/i.test(voice.identifier) || /network/i.test(voice.name ?? '');
}

const NOVELTY_VOICE_NAMES: Set<string> = new Set<string>([
  'albert', 'badnews', 'bahh', 'bells', 'boing', 'bubbles', 'cellos', 'deranged', 'goodnews',
  'hysterical', 'jester', 'junior', 'organ', 'princess', 'ralph', 'superstar', 'trinoids', 'whisper',
  'wobble', 'zarvox',
]);

function noveltyKey(voice: ListedVoice): string {
  const named = voice.name?.trim();
  const source = named && named !== voice.identifier ? named : voice.identifier;
  const leaf = source.split(/[./]/).pop() ?? source;
  return leaf.toLowerCase().replace(/[^a-z0-9]/g, '');
}

function isNoveltyVoice(voice: ListedVoice): boolean {
  return NOVELTY_VOICE_NAMES.has(noveltyKey(voice));
}

/** Languages whose main regional voice is a good fallback when the device's own has none. */
const PRIMARY_VOICE_LOCALES: string[] = ['en', 'de', 'ru', 'fr', 'es', 'ja', 'zh-CN'];
const PRIMARY_VOICE_TAGS: Record<string, string> = {};
PRIMARY_VOICE_TAGS['en'] = 'en-US';
PRIMARY_VOICE_TAGS['de'] = 'de-DE';
PRIMARY_VOICE_TAGS['ru'] = 'ru-RU';
PRIMARY_VOICE_TAGS['fr'] = 'fr-FR';
PRIMARY_VOICE_TAGS['es'] = 'es-ES';
PRIMARY_VOICE_TAGS['ja'] = 'ja-JP';
PRIMARY_VOICE_TAGS['zh-CN'] = 'zh-CN';

/** Lowercase voice locales to fall back on, best first, when the device's own has no voice. */
function primaryLocales(locale: string, region: string | null): string[] {
  const parts = locale.split('-');
  const language = parts[0] ?? '';
  const country = region === null ? undefined : region;
  // Outside Spain a Latin American voice sounds closer than Castilian.
  if (language === 'es' && country && country !== 'es') {
    return ['es-mx', 'es-us', 'es-es'];
  }
  const primary = PRIMARY_VOICE_LOCALES.find((code: string): boolean => code.split('-')[0] === language);
  return primary !== undefined ? [(PRIMARY_VOICE_TAGS[primary] ?? primary).toLowerCase()] : [];
}

/** The voices a bot may be given: the device language's own, on-device, no novelty voices (mobile deviceVoices). */
export function assignableDeviceVoices(listed: ListedVoice[], deviceLanguage: string): ListedVoice[] {
  const kept: ListedVoice[] = [];
  for (const voice of listed) {
    const language = (voice.language ?? '').toLowerCase().split('-')[0] ?? '';
    if (!isNetworkVoice(voice) && !isNoveltyVoice(voice) && language === deviceLanguage) {
      kept.push(voice);
    }
  }
  return kept.sort((left: ListedVoice, right: ListedVoice): number => left.identifier.localeCompare(right.identifier));
}

/**
 * The voice a bot speaks with from `available`, given the voices other bots already hold. It
 * hands it one no other bot has yet when it has none; undefined when the device offers no voice.
 */
export function chooseBotVoice(available: ListedVoice[], assignments: Record<string, string> | null,
  botId: string, locale: string, region: string | null): string | undefined {
  const voices = available.map((voice: ListedVoice): string => voice.identifier);
  if (voices.length === 0) {
    return undefined;
  }
  const current = assignments !== null ? assignments[botId] : undefined;
  if (current !== undefined && voices.includes(current)) {
    return current;
  }
  const taken = new Set<string>();
  if (assignments !== null) {
    for (const id of Object.keys(assignments)) {
      if (id !== botId) {
        const voice = assignments[id];
        if (voice !== undefined) {
          taken.add(voice);
        }
      }
    }
  }
  const sameLocale = available.filter((voice: ListedVoice): boolean => {
    const tag = voice.language.toLowerCase();
    return tag === locale || (region !== null && region !== '' && tag.split('-').slice(1).includes(region));
  });
  let primaryRegion: ListedVoice[] = [];
  for (const tag of primaryLocales(locale, region)) {
    const matching = available.filter((voice: ListedVoice): boolean => voice.language.toLowerCase() === tag);
    if (matching.length > 0) {
      primaryRegion = matching;
      break;
    }
  }
  const candidates = sameLocale.length > 0 ? sameLocale : primaryRegion.length > 0 ? primaryRegion : available;
  const unused = candidates.filter((voice: ListedVoice): boolean => !taken.has(voice.identifier));
  const pool = unused.length > 0 ? unused : candidates;
  const higherQuality = pool.filter((voice: ListedVoice): boolean =>
    voice.quality === 'Enhanced' || voice.quality === 'Premium');
  const assignable = (higherQuality.length > 0 ? higherQuality : pool)
    .map((voice: ListedVoice): string => voice.identifier);
  return pickUnusedVoice(assignable, taken, botId);
}
