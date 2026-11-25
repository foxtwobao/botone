// Voice settings rules (M7): the two pure decisions of mobile's voice settings screen
// (app/(settings)/voice.tsx) and of the connection form (packages/contracts voice-connection-ui):
// which connection the screen shows, and what its form offers. The layer-2 voice fixture runs the
// real rules and this port replays them. The settings screen that uses them is
// stores/voice-settings-store.ets.
import type { VoiceCatalogView, VoiceCredentialView, VoiceStatusView } from '../contract/decode-voice';

/** The protocol whose connection names its own server (contracts model-connections). */
export const SELF_HOSTED_PROTOCOL = 'openai-compatible';

/** The connection to show: the one asked for, the one in use, else the catalog's first. */
export function pickProvider(catalog: VoiceCatalogView[], status: VoiceStatusView, preferred?: string): string {
  const asked = preferred !== undefined && catalog.some((entry: VoiceCatalogView): boolean => entry.id === preferred)
    ? preferred : '';
  const inUse = status.provider !== null
    && catalog.some((entry: VoiceCatalogView): boolean => entry.id === status.provider) ? status.provider : '';
  const chosen = asked !== '' ? asked : inUse;
  if (chosen !== '') {
    return chosen;
  }
  return catalog.length > 0 ? catalog[0]!.id : '';
}

export interface VoiceConnectionInput {
  /** The catalog entry of the chosen connection; undefined until the catalog has loaded. */
  entry: VoiceCatalogView | undefined;
  credential: VoiceCredentialView | undefined;
  apiKey: string;
  baseUrl: string;
}

export interface VoiceConnectionForm {
  /** The account's model connection can stand in for a key, so the key is optional. */
  keyOptional: boolean;
  /** Connected through that model connection: there is no key to show or replace. */
  linked: boolean;
  canConnect: boolean;
}

/**
 * What the form offers for a connection. Until it is connected, the account's model connection
 * can stand in for a key; once linked there is no key to show or replace. As the rule is written,
 * only the self-hosted address replaces the key: with no connection chosen, a key alone reads
 * as enough (the screen never connects without one).
 */
export function voiceConnectionForm(input: VoiceConnectionInput): VoiceConnectionForm {
  const entry = input.entry;
  const keyOptional = entry !== undefined && entry.modelConnection === true && input.credential === undefined;
  const typedKey = input.apiKey.trim();
  let canConnect = entry !== undefined && entry.keyless === true;
  if (!canConnect) {
    canConnect = entry !== undefined && entry.id === SELF_HOSTED_PROTOCOL
      ? input.baseUrl.trim().length > 0
      : typedKey.length >= 8 || (keyOptional && typedKey.length === 0);
  }
  const form: VoiceConnectionForm = {
    keyOptional: keyOptional,
    linked: input.credential !== undefined && input.credential.hasKey === false,
    canConnect: canConnect,
  };
  return form;
}
