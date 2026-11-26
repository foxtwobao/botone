// The bots' device voices (M7): mobile's lib/voice/bot-voices.ts wiring over the device's own
// list. Each bot is handed a voice of the device's language no other bot has yet, the assignment
// saved in the voice preferences file, one write at a time so concurrent bots keep distinct
// voices. The pure choice (assignableDeviceVoices, chooseBotVoice) is a port the layer-2 voice
// fixture replays; this module only feeds it the device's list and saves what it picks.
import type { textToSpeech } from '@kit.CoreSpeechKit';
import { i18n } from '@kit.LocalizationKit';
import { assignableDeviceVoices, chooseBotVoice } from './bot-voices';
import type { ListedVoice } from './bot-voices';
import { installedVoices, voiceIdentifier } from './device-speech';
import { loadBotVoices, saveBotVoices } from './voice-prefs';

/** The device's own preference order: a language tag and its region when it has one. */
interface DeviceLocale {
  locale: string;
  region: string | null;
}

function deviceLocale(): DeviceLocale {
  const tag = i18n.System.getSystemLanguage().toLowerCase();
  const parts = tag.split('-');
  const second = parts.length > 1 ? parts[1] ?? '' : '';
  const found: DeviceLocale = { locale: tag, region: second.length === 2 ? second : null };
  return found;
}

/** The voices a bot may be given, from the device's own list. */
function assignableVoices(listed: textToSpeech.VoiceInfo[]): ListedVoice[] {
  const rows: ListedVoice[] = [];
  for (const voice of listed) {
    const row: ListedVoice = {
      identifier: voiceIdentifier(voice),
      language: voice.language.replace('_', '-'),
      name: voice.description,
    };
    rows.push(row);
  }
  return assignableDeviceVoices(rows, deviceLocale().locale.split('-')[0] ?? '');
}

/** Assignment updates run one at a time, so concurrent bots keep distinct voices. */
let queue: Promise<void> = Promise.resolve();

function serialized<T>(work: () => Promise<T>): Promise<T> {
  const run = queue.then(work, work);
  queue = run.then((): void => undefined, (): void => undefined);
  return run;
}

/**
 * The voice a bot speaks with, handing it one no other bot has yet if it has none; undefined when
 * the device offers the language no voice.
 */
export function voiceForBot(botId: string): Promise<string | undefined> {
  return serialized(async (): Promise<string | undefined> => {
    const available = assignableVoices(await installedVoices());
    if (available.length === 0) {
      return undefined;
    }
    const device = deviceLocale();
    const assignments = await loadBotVoices();
    const chosen = chooseBotVoice(available, assignments, botId, device.locale, device.region);
    if (chosen === undefined) {
      return undefined;
    }
    const next: Record<string, string> = {};
    if (assignments !== null) {
      for (const key of Object.keys(assignments)) {
        next[key] = assignments[key];
      }
    }
    next[botId] = chosen;
    await saveBotVoices(next);
    return chosen;
  });
}
