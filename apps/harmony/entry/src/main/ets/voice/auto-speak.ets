// Auto-speak decision (M7): a port of mobile's lib/voice/auto-speak.ts. It decides whether a bot's
// finished reply should be read aloud: skip history, wait out in-flight runs, speak only a reply
// that arrived since the last one spoken. Pure; the layer-2 voice fixture is generated from the
// real mobile module.
import type { Blocks } from '../thread/message-text';
import { speechFromBlocks } from './speech-text';

const IN_PROGRESS_RUN_STATUSES: string[] = ['running', 'queued', 'leased'];

/** A message as the decision reads it. */
export interface AutoSpeakMessage {
  id: string;
  role: string;
  blocks: Blocks;
}

export interface AutoSpeakInput {
  botId: string;
  autoSpeak: boolean;
  /** An active call owns the speaker; replies only seed while it lasts. */
  callActive: boolean;
  focused: boolean;
  snapshotReady: boolean;
  lastSpokenBotId: string | null;
  lastSpokenMessageId: string | null;
  runStatus?: string;
  messages: AutoSpeakMessage[];
}

/** Remember the newest bot message as spoken without reading it. */
export interface AutoSpeakSeed {
  action: 'seed';
  messageId: string | null;
}

export interface AutoSpeakWait {
  action: 'wait';
}

export interface AutoSpeakSpeech {
  action: 'speak';
  messageId: string;
  text: string;
}

export type AutoSpeakDecision = AutoSpeakSeed | AutoSpeakWait | AutoSpeakSpeech;

function seed(messageId: string | null): AutoSpeakSeed {
  const decision: AutoSpeakSeed = { action: 'seed', messageId: messageId };
  return decision;
}

function wait(): AutoSpeakWait {
  const decision: AutoSpeakWait = { action: 'wait' };
  return decision;
}

/** Same speak-on-finish gate as mobile and web: skip history, wait out in-flight runs. */
export function nextAutoSpeakAction(input: AutoSpeakInput): AutoSpeakDecision {
  if (!input.snapshotReady) {
    return wait();
  }
  let lastBot: AutoSpeakMessage | null = null;
  for (let index = input.messages.length - 1; index >= 0; index -= 1) {
    const message = input.messages[index];
    if (message.role === 'bot') {
      lastBot = message;
      break;
    }
  }
  const lastBotId = lastBot !== null ? lastBot.id : null;
  if (input.lastSpokenBotId !== input.botId) {
    return seed(lastBotId);
  }
  // An active call owns the speaker: seed before the run and focus gates, so a reply that streams
  // during the call stays unspoken once the call ends.
  if (input.callActive || !input.autoSpeak) {
    return seed(lastBotId);
  }
  if (!input.focused) {
    return wait();
  }
  if (input.runStatus && IN_PROGRESS_RUN_STATUSES.includes(input.runStatus)) {
    return wait();
  }
  if (lastBot === null || lastBot.id === input.lastSpokenMessageId) {
    return wait();
  }
  const text = speechFromBlocks(lastBot.blocks).trim();
  if (!text) {
    return seed(lastBot.id);
  }
  const decision: AutoSpeakSpeech = { action: 'speak', messageId: lastBot.id, text: text };
  return decision;
}
